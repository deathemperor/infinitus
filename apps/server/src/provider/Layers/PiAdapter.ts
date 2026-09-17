/**
 * PiAdapter — Pi CLI (`pi --mode rpc`) over its own JSONL RPC.
 *
 * Pi does not speak ACP, so this adapter owns the translation from Pi's event
 * vocabulary into orchestration events directly, the way the Codex adapter
 * does for the app-server protocol. {@link ./PiSessionRuntime.ts} owns the
 * process and the wire; this module owns the meaning.
 *
 * @module PiAdapter
 */
import {
  EventId,
  PI_DEFAULT_MODEL,
  ProviderDriverKind,
  ProviderInstanceId,
  RuntimeItemId,
  ThreadId,
  TurnId,
  type PiSettings,
  type ProviderRuntimeEvent,
  type ProviderSession,
  type RuntimeMode,
} from "@infinitus/contracts";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as FileSystem from "effect/FileSystem";
import * as Option from "effect/Option";
import * as PubSub from "effect/PubSub";
import * as Schema from "effect/Schema";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import { ChildProcessSpawner } from "effect/unstable/process";

import { resolveAttachmentPath } from "../../attachmentStore.ts";
import {
  ProviderAdapterProcessError,
  ProviderAdapterRequestError,
  ProviderAdapterSessionNotFoundError,
  ProviderAdapterValidationError,
} from "../Errors.ts";
import type { PiAdapterShape } from "../Services/PiAdapter.ts";
import type { EventNdjsonLogger } from "./EventNdjsonLogger.ts";
import {
  makePiSessionRuntime,
  type PiSessionRuntimeShape,
  type PiRpcTransportError,
} from "./PiSessionRuntime.ts";
import { piCanonicalItemType, piMessageText, type PiRpcRecord } from "./piRpcProtocol.ts";

const PROVIDER = ProviderDriverKind.make("pi");

const PiResumeCursor = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  sessionId: Schema.NonEmptyString,
});
const decodePiResumeCursor = Schema.decodeUnknownOption(PiResumeCursor);

/**
 * Runtime modes this adapter will run.
 *
 * Pi ships no permission system — its README says so, and a live RPC run
 * wrote a file with no approval event of any kind: no permission request, no
 * `extension_ui_request`, nothing to answer. Mapping a supervised mode onto
 * that would hand the user an ungated agent while the UI claimed otherwise,
 * so the supervised modes are refused rather than silently downgraded.
 */
const SUPPORTED_RUNTIME_MODES: ReadonlySet<RuntimeMode> = new Set<RuntimeMode>(["full-access"]);

const UNSUPPORTED_RUNTIME_MODE_DETAIL =
  "Pi has no permission system: it runs every tool with the permissions of the " +
  "process that launched it, and its RPC protocol has no approval request to " +
  "answer. Use Full access, or run Pi in a container.";

export interface PiAdapterOptions {
  readonly instanceId?: ProviderInstanceId;
  readonly environment?: NodeJS.ProcessEnv;
  readonly nativeEventLogger?: EventNdjsonLogger;
  /** Where chat attachments live. Without it image attachments are not sent. */
  readonly attachmentsDir?: string;
}

interface PiSessionContext {
  readonly threadId: ThreadId;
  session: ProviderSession;
  readonly scope: Scope.Closeable;
  readonly runtime: PiSessionRuntimeShape;
  readonly sessionId: string;
  recordFiber: Fiber.Fiber<void, never> | undefined;
  activeTurnId: TurnId | undefined;
  /** Settles when Pi emits `agent_settled` for the turn in flight. */
  turnSettled: Deferred.Deferred<PiTurnOutcome> | undefined;
  /**
   * How the latest assistant message of the run ended. Read only at
   * `agent_settled`: an errored message may still be retried, and an aborted
   * one leaves Pi busy until it settles.
   */
  lastAssistantStop: PiTurnOutcome;
  /** Live tool calls by Pi's `toolCallId`, so `_end` can close the right item. */
  readonly openToolCalls: Map<string, string>;
  readonly turns: Array<{ id: TurnId; items: Array<unknown> }>;
  stopped: boolean;
}

type PiTurnOutcome =
  | { readonly kind: "completed" }
  | { readonly kind: "aborted" }
  | { readonly kind: "failed"; readonly message: string };

export const makePiAdapter = Effect.fn("makePiAdapter")(function* (
  piSettings: PiSettings,
  options?: PiAdapterOptions,
) {
  const boundInstanceId = options?.instanceId ?? ProviderInstanceId.make("pi");
  const childProcessSpawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const crypto = yield* Crypto.Crypto;
  const fileSystem = yield* FileSystem.FileSystem;
  const nativeEventLogger = options?.nativeEventLogger;
  const sessions = new Map<ThreadId, PiSessionContext>();
  const runtimeEventPubSub = yield* PubSub.unbounded<ProviderRuntimeEvent>();

  const nowIso = Effect.map(DateTime.now, DateTime.formatIso);
  const randomUUIDv4 = crypto.randomUUIDv4.pipe(
    Effect.mapError(
      (cause) =>
        new ProviderAdapterRequestError({
          provider: PROVIDER,
          method: "crypto/randomUUIDv4",
          detail: "Failed to generate a Pi runtime identifier.",
          cause,
        }),
    ),
  );
  const makeEventStamp = () =>
    Effect.all({ eventId: Effect.map(randomUUIDv4, EventId.make), createdAt: nowIso });

  const offerRuntimeEvent = (event: ProviderRuntimeEvent) =>
    PubSub.publish(runtimeEventPubSub, event).pipe(Effect.asVoid);

  const logNative = (threadId: ThreadId, record: PiRpcRecord) =>
    Effect.gen(function* () {
      if (!nativeEventLogger) return;
      const observedAt = yield* nowIso;
      yield* nativeEventLogger.write(
        {
          observedAt,
          event: {
            id: yield* randomUUIDv4,
            kind: "notification",
            provider: PROVIDER,
            providerInstanceId: boundInstanceId,
            createdAt: observedAt,
            method: "type" in record ? record.type : record.unrecognizedType,
            threadId,
            payload: record,
          },
        },
        threadId,
      );
    }).pipe(Effect.ignore);

  const requireSession = (threadId: ThreadId) => {
    const ctx = sessions.get(threadId);
    if (!ctx || ctx.stopped) {
      return Effect.fail(new ProviderAdapterSessionNotFoundError({ provider: PROVIDER, threadId }));
    }
    return Effect.succeed(ctx);
  };

  const mapTransportError = (threadId: ThreadId, method: string) => (cause: PiRpcTransportError) =>
    new ProviderAdapterRequestError({
      provider: PROVIDER,
      method,
      detail: cause.detail,
      cause,
    });

  /**
   * Translates one Pi record into orchestration events.
   *
   * The `message_update` arm is where Pi is easiest to get wrong: thinking and
   * text arrive as SEPARATE streams on their own `contentIndex` values, so
   * routing must switch on the delta's own `type`. Merging by `contentIndex`
   * glues the model's private reasoning onto its answer — a real bug hit while
   * probing this protocol, where a sample carried 25 thinking deltas to 1 text
   * delta.
   */
  const handleRecord = (ctx: PiSessionContext, record: PiRpcRecord) =>
    Effect.gen(function* () {
      yield* logNative(ctx.threadId, record);
      const turnId = ctx.activeTurnId;
      // Pi is pre-1.0; an event this build does not know is logged above and
      // otherwise ignored.
      if (!("type" in record)) return;

      switch (record.type) {
        // The command acknowledgement. `success: false` means Pi rejected the
        // prompt before accepting it (a bad model, a malformed command), and
        // no further events will follow for it — without settling here the
        // turn waits on a deferred nothing will ever complete.
        case "response": {
          if (record.success || record.command !== "prompt") return;
          yield* settleTurn(ctx, {
            kind: "failed",
            message: record.error ?? "Pi rejected the prompt.",
          });
          return;
        }

        case "message_update": {
          const event = record.assistantMessageEvent;
          const delta = event.delta ?? "";
          if (delta.length === 0) return;
          if (event.type === "text_delta") {
            yield* offerRuntimeEvent({
              type: "content.delta",
              ...(yield* makeEventStamp()),
              provider: PROVIDER,
              providerInstanceId: boundInstanceId,
              threadId: ctx.threadId,
              ...(turnId ? { turnId } : {}),
              payload: {
                streamKind: "assistant_text",
                delta,
                ...(typeof event.contentIndex === "number"
                  ? { contentIndex: event.contentIndex }
                  : {}),
              },
            });
            return;
          }
          if (event.type === "thinking_delta") {
            yield* offerRuntimeEvent({
              type: "content.delta",
              ...(yield* makeEventStamp()),
              provider: PROVIDER,
              providerInstanceId: boundInstanceId,
              threadId: ctx.threadId,
              ...(turnId ? { turnId } : {}),
              payload: {
                streamKind: "reasoning_text",
                delta,
                ...(typeof event.contentIndex === "number"
                  ? { contentIndex: event.contentIndex }
                  : {}),
              },
            });
          }
          return;
        }

        case "tool_execution_start": {
          const itemId = RuntimeItemId.make(record.toolCallId);
          ctx.openToolCalls.set(record.toolCallId, record.toolName);
          yield* offerRuntimeEvent({
            type: "item.started",
            ...(yield* makeEventStamp()),
            provider: PROVIDER,
            providerInstanceId: boundInstanceId,
            threadId: ctx.threadId,
            ...(turnId ? { turnId } : {}),
            itemId,
            payload: {
              itemType: piCanonicalItemType(record.toolName),
              status: "inProgress",
              title: record.toolName,
              ...(record.args !== undefined ? { data: record.args } : {}),
            },
          });
          return;
        }

        case "tool_execution_end": {
          const itemId = RuntimeItemId.make(record.toolCallId);
          ctx.openToolCalls.delete(record.toolCallId);
          yield* offerRuntimeEvent({
            type: "item.completed",
            ...(yield* makeEventStamp()),
            provider: PROVIDER,
            providerInstanceId: boundInstanceId,
            threadId: ctx.threadId,
            ...(turnId ? { turnId } : {}),
            itemId,
            payload: {
              itemType: piCanonicalItemType(record.toolName),
              status: record.isError === true ? "failed" : "completed",
              title: record.toolName,
              ...(record.result !== undefined ? { data: record.result } : {}),
            },
          });
          return;
        }

        case "message_end": {
          // Pi echoes `message_start`/`message_end` for the USER message and
          // for tool results too, so the role has to be checked before any of
          // this is treated as assistant output.
          if (record.message.role !== "assistant") return;
          const text = piMessageText(record.message);
          if (text.length > 0) {
            const itemId = RuntimeItemId.make(`${ctx.sessionId}:assistant:${yield* randomUUIDv4}`);
            yield* offerRuntimeEvent({
              type: "item.completed",
              ...(yield* makeEventStamp()),
              provider: PROVIDER,
              providerInstanceId: boundInstanceId,
              threadId: ctx.threadId,
              ...(turnId ? { turnId } : {}),
              itemId,
              payload: { itemType: "assistant_message", status: "completed", detail: text },
            });
          }
          ctx.lastAssistantStop =
            record.message.stopReason === "aborted"
              ? { kind: "aborted" }
              : record.message.stopReason === "error"
                ? {
                    kind: "failed",
                    message: record.message.errorMessage ?? "Pi reported a model error.",
                  }
                : { kind: "completed" };
          return;
        }

        case "compaction_end": {
          yield* offerRuntimeEvent({
            type: "thread.state.changed",
            ...(yield* makeEventStamp()),
            provider: PROVIDER,
            providerInstanceId: boundInstanceId,
            threadId: ctx.threadId,
            payload: { state: "compacted" },
          });
          return;
        }

        // Pi's terminal event for a prompt. Deliberately NOT `agent_end`:
        // that fires per low-level agent run and may still be followed by an
        // automatic retry, a compaction retry, or a queued message. A
        // tool-using turn emits two `turn_end`s for one prompt, so keying on
        // either would settle the turn while work was still running. An
        // aborted `message_end` does not settle it either: Pi refuses the
        // next prompt until this event, which always follows.
        case "agent_settled": {
          yield* settleTurn(ctx, ctx.lastAssistantStop);
          return;
        }

        default:
          return;
      }
    });

  /** Resolves the in-flight turn's deferred exactly once. */
  const settleTurn = (ctx: PiSessionContext, outcome: PiTurnOutcome) =>
    Effect.gen(function* () {
      const pending = ctx.turnSettled;
      if (!pending) return;
      yield* Deferred.succeed(pending, outcome).pipe(Effect.ignore);
    });

  /**
   * Tears a session down once.
   *
   * `interruptRecordFiber` is the one thing the two callers disagree on:
   * {@link stopSession} is interrupting a live child and must stop the fiber
   * reading it, while the record fiber tearing ITSELF down on child exit must
   * not — interrupting the running fiber from inside itself would never
   * return, and the stream has already ended anyway.
   */
  /**
   * Drops a turn's bookkeeping from the session.
   *
   * Pi keeps the session alive between prompts and still emits records on it
   * (a late `message_end`, an extension's chatter). Leaving the turn active
   * would stamp those with a turn the orchestrator has already closed — or,
   * when the prompt never reached the child at all, with one that never ran.
   */
  const clearActiveTurn = (ctx: PiSessionContext, turnId: TurnId) =>
    Effect.gen(function* () {
      ctx.turnSettled = undefined;
      if (ctx.activeTurnId === turnId) ctx.activeTurnId = undefined;
      const { activeTurnId: _cleared, ...idleSession } = ctx.session;
      ctx.session = { ...idleSession, updatedAt: yield* nowIso };
    });

  const stopSessionInternal = (
    ctx: PiSessionContext,
    options?: {
      readonly exitKind?: "graceful" | "error";
      readonly turnOutcome?: PiTurnOutcome;
      readonly interruptRecordFiber?: boolean;
    },
  ) =>
    Effect.gen(function* () {
      if (ctx.stopped) return;
      ctx.stopped = true;
      sessions.delete(ctx.threadId);
      // A turn still waiting would otherwise hang forever on a killed child.
      yield* settleTurn(ctx, options?.turnOutcome ?? { kind: "aborted" });
      if (ctx.recordFiber && options?.interruptRecordFiber !== false) {
        yield* Fiber.interrupt(ctx.recordFiber).pipe(Effect.ignore);
      }
      yield* Effect.ignore(Scope.close(ctx.scope, Exit.void));
      yield* offerRuntimeEvent({
        type: "session.exited",
        ...(yield* makeEventStamp()),
        provider: PROVIDER,
        providerInstanceId: boundInstanceId,
        threadId: ctx.threadId,
        payload: { exitKind: options?.exitKind ?? "graceful" },
      });
    });

  const startSession: PiAdapterShape["startSession"] = (input) =>
    Effect.gen(function* () {
      if (input.provider !== undefined && input.provider !== PROVIDER) {
        return yield* new ProviderAdapterValidationError({
          provider: PROVIDER,
          operation: "startSession",
          issue: `Expected provider '${PROVIDER}' but received '${input.provider}'.`,
        });
      }
      if (!input.cwd?.trim()) {
        return yield* new ProviderAdapterValidationError({
          provider: PROVIDER,
          operation: "startSession",
          issue: "cwd is required and must be non-empty.",
        });
      }
      if (!SUPPORTED_RUNTIME_MODES.has(input.runtimeMode)) {
        return yield* new ProviderAdapterRequestError({
          provider: PROVIDER,
          method: "session/start",
          detail: UNSUPPORTED_RUNTIME_MODE_DETAIL,
        });
      }

      const existing = sessions.get(input.threadId);
      if (existing && !existing.stopped) yield* stopSessionInternal(existing);

      // `--session-id` is exact and creates the session when absent, so a
      // fresh id and a resumed one take the identical path.
      const resumeSessionId = Option.map(
        decodePiResumeCursor(input.resumeCursor),
        (cursor) => cursor.sessionId,
      );
      const resolvedSessionId = Option.isSome(resumeSessionId)
        ? resumeSessionId.value
        : `t3-${yield* randomUUIDv4}`;

      const piModel =
        input.modelSelection?.instanceId === boundInstanceId &&
        input.modelSelection.model !== PI_DEFAULT_MODEL
          ? input.modelSelection.model
          : undefined;

      const sessionScope = yield* Scope.make("sequential");
      let sessionScopeTransferred = false;
      yield* Effect.addFinalizer(() =>
        sessionScopeTransferred ? Effect.void : Scope.close(sessionScope, Exit.void),
      );

      const runtime = yield* makePiSessionRuntime(piSettings, {
        cwd: input.cwd.trim(),
        ...(piSettings.homePath ? { homePath: piSettings.homePath } : {}),
        environment: options?.environment ?? process.env,
        ...(piModel ? { model: piModel } : {}),
        sessionId: resolvedSessionId,
      }).pipe(
        Effect.provideService(Scope.Scope, sessionScope),
        Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, childProcessSpawner),
        Effect.mapError(
          (cause) =>
            new ProviderAdapterProcessError({
              provider: PROVIDER,
              threadId: input.threadId,
              detail: cause.detail,
              cause,
            }),
        ),
      );

      const now = yield* nowIso;
      const session: ProviderSession = {
        provider: PROVIDER,
        providerInstanceId: boundInstanceId,
        status: "ready",
        runtimeMode: input.runtimeMode,
        cwd: input.cwd.trim(),
        ...(piModel ? { model: piModel } : {}),
        threadId: input.threadId,
        resumeCursor: { schemaVersion: 1, sessionId: resolvedSessionId },
        createdAt: now,
        updatedAt: now,
      };

      const ctx: PiSessionContext = {
        threadId: input.threadId,
        session,
        scope: sessionScope,
        runtime,
        sessionId: resolvedSessionId,
        recordFiber: undefined,
        activeTurnId: undefined,
        turnSettled: undefined,
        lastAssistantStop: { kind: "completed" },
        openToolCalls: new Map(),
        turns: [],
        stopped: false,
      };

      // Forked into the session scope, not the calling fiber: Effect
      // interrupts a fiber's children when it completes, so a fork here would
      // die the moment `startSession` returned and drop every later record.
      ctx.recordFiber = yield* runtime.records.pipe(
        Stream.runForEach((record) => handleRecord(ctx, record)),
        Effect.catchCause((cause) =>
          Effect.logError("Failed to process a Pi runtime record.", { cause }),
        ),
        Effect.andThen(
          // The child exited, so the session is gone whether or not anyone
          // asked for it. Tearing it down here settles a waiting turn, drops
          // the context (a later `requireSession` would otherwise hand out a
          // session whose child is dead) and closes the scope. The record
          // fiber is this fiber, so it is not interrupted.
          stopSessionInternal(ctx, {
            exitKind: "error",
            turnOutcome: { kind: "failed", message: "The Pi process exited." },
            interruptRecordFiber: false,
          }).pipe(
            Effect.catchCause((cause) =>
              Effect.logError("Failed to tear down an exited Pi session.", { cause }),
            ),
          ),
        ),
        Effect.forkIn(sessionScope),
      );

      sessions.set(input.threadId, ctx);
      sessionScopeTransferred = true;

      yield* offerRuntimeEvent({
        type: "session.started",
        ...(yield* makeEventStamp()),
        provider: PROVIDER,
        providerInstanceId: boundInstanceId,
        threadId: input.threadId,
        payload: {},
      });
      yield* offerRuntimeEvent({
        type: "session.state.changed",
        ...(yield* makeEventStamp()),
        provider: PROVIDER,
        providerInstanceId: boundInstanceId,
        threadId: input.threadId,
        payload: { state: "ready", reason: "Pi RPC session ready" },
      });
      yield* offerRuntimeEvent({
        type: "thread.started",
        ...(yield* makeEventStamp()),
        provider: PROVIDER,
        providerInstanceId: boundInstanceId,
        threadId: input.threadId,
        payload: { providerThreadId: resolvedSessionId },
      });

      return session;
    }).pipe(Effect.scoped);

  const sendTurn: PiAdapterShape["sendTurn"] = (input) =>
    Effect.gen(function* () {
      const ctx = yield* requireSession(input.threadId);
      const prompt = input.input?.trim() ?? "";
      // Pi's `prompt` takes images beside the text. Other files reach it
      // through the path line ProviderService puts in the prompt.
      const images: Array<{ type: "image"; data: string; mimeType: string }> = [];
      for (const attachment of options?.attachmentsDir ? (input.attachments ?? []) : []) {
        if (attachment.type !== "image") continue;
        const attachmentPath = resolveAttachmentPath({
          attachmentsDir: options?.attachmentsDir ?? "",
          attachment,
        });
        if (!attachmentPath) {
          return yield* new ProviderAdapterRequestError({
            provider: PROVIDER,
            method: "prompt",
            detail: `Invalid attachment id '${attachment.id}'.`,
          });
        }
        const bytes = yield* fileSystem.readFile(attachmentPath).pipe(
          Effect.mapError(
            (cause) =>
              new ProviderAdapterRequestError({
                provider: PROVIDER,
                method: "prompt",
                detail: cause.message,
                cause,
              }),
          ),
        );
        images.push({
          type: "image",
          data: Buffer.from(bytes).toString("base64"),
          mimeType: attachment.mimeType,
        });
      }
      if (prompt.length === 0 && images.length === 0) {
        return yield* new ProviderAdapterValidationError({
          provider: PROVIDER,
          operation: "sendTurn",
          issue: "Turn requires non-empty text or an image.",
        });
      }

      const turnId = TurnId.make(yield* randomUUIDv4);
      const settled = yield* Deferred.make<PiTurnOutcome>();
      ctx.activeTurnId = turnId;
      ctx.turnSettled = settled;
      ctx.lastAssistantStop = { kind: "completed" };
      ctx.session = { ...ctx.session, activeTurnId: turnId, updatedAt: yield* nowIso };

      yield* offerRuntimeEvent({
        type: "turn.started",
        ...(yield* makeEventStamp()),
        provider: PROVIDER,
        providerInstanceId: boundInstanceId,
        threadId: input.threadId,
        turnId,
        ...(ctx.session.model ? { payload: { model: ctx.session.model } } : { payload: {} }),
      });

      // The turn is announced before the prompt goes out, so a send that
      // fails has to retire it again — and tell anyone listening, who would
      // otherwise be left waiting on a `turn.started` that never completes.
      yield* ctx.runtime
        .send({
          id: turnId,
          type: "prompt",
          message: prompt,
          ...(images.length > 0 ? { images } : {}),
        })
        .pipe(
          Effect.mapError(mapTransportError(input.threadId, "prompt")),
          Effect.tapError((error) =>
            Effect.gen(function* () {
              yield* clearActiveTurn(ctx, turnId);
              yield* offerRuntimeEvent({
                type: "turn.completed",
                ...(yield* makeEventStamp()),
                provider: PROVIDER,
                providerInstanceId: boundInstanceId,
                threadId: input.threadId,
                turnId,
                payload: { state: "failed", errorMessage: error.message },
              });
            }),
          ),
        );

      const outcome = yield* Deferred.await(settled);
      yield* clearActiveTurn(ctx, turnId);
      ctx.turns.push({ id: turnId, items: [{ prompt, outcome }] });

      if (outcome.kind === "failed") {
        const stderr = (yield* ctx.runtime.stderr).trim();
        yield* offerRuntimeEvent({
          type: "turn.completed",
          ...(yield* makeEventStamp()),
          provider: PROVIDER,
          providerInstanceId: boundInstanceId,
          threadId: input.threadId,
          turnId,
          payload: { state: "failed", errorMessage: outcome.message },
        });
        return yield* new ProviderAdapterRequestError({
          provider: PROVIDER,
          method: "prompt",
          detail: stderr.length > 0 ? `${outcome.message} ${stderr}` : outcome.message,
        });
      }

      yield* offerRuntimeEvent(
        outcome.kind === "aborted"
          ? {
              type: "turn.aborted",
              ...(yield* makeEventStamp()),
              provider: PROVIDER,
              providerInstanceId: boundInstanceId,
              threadId: input.threadId,
              turnId,
              payload: { reason: "The turn was interrupted." },
            }
          : {
              type: "turn.completed",
              ...(yield* makeEventStamp()),
              provider: PROVIDER,
              providerInstanceId: boundInstanceId,
              threadId: input.threadId,
              turnId,
              payload: { state: "completed" },
            },
      );

      return { threadId: input.threadId, turnId, resumeCursor: ctx.session.resumeCursor };
    });

  /**
   * Interrupts the running turn.
   *
   * Pi answers `abort` only once the session has gone idle — its own docs say
   * the command "wait[s] for the session to become idle before responding",
   * and a live run took 14 seconds to acknowledge one. Nothing here waits for
   * that: `send` only enqueues the command onto the unbounded stdin queue and
   * returns, so the caller is never blocked. Streaming stops on Pi's side and
   * the turn's `message_end` carries `stopReason: "aborted"`, so the turn
   * settles as aborted at `agent_settled`, like any other outcome.
   */
  const interruptTurn: PiAdapterShape["interruptTurn"] = (threadId) =>
    Effect.gen(function* () {
      const ctx = yield* requireSession(threadId);
      yield* ctx.runtime
        .send({ type: "abort" })
        .pipe(Effect.mapError(mapTransportError(threadId, "abort")));
    });

  const compactThread = (threadId: ThreadId) =>
    Effect.gen(function* () {
      const ctx = yield* requireSession(threadId);
      yield* ctx.runtime
        .send({ type: "compact" })
        .pipe(Effect.mapError(mapTransportError(threadId, "compact")));
    });

  const respondToRequest: PiAdapterShape["respondToRequest"] = (threadId) =>
    Effect.gen(function* () {
      yield* requireSession(threadId);
      // Unreachable in practice: Pi opens no approval requests, so nothing
      // ever produces a request id for the client to answer.
      return yield* new ProviderAdapterRequestError({
        provider: PROVIDER,
        method: "respondToRequest",
        detail: "Pi does not open approval requests.",
      });
    });

  const respondToUserInput: PiAdapterShape["respondToUserInput"] = (threadId) =>
    Effect.gen(function* () {
      yield* requireSession(threadId);
      return yield* new ProviderAdapterRequestError({
        provider: PROVIDER,
        method: "respondToUserInput",
        detail: "Pi does not open user-input requests.",
      });
    });

  const readThread: PiAdapterShape["readThread"] = (threadId) =>
    Effect.gen(function* () {
      const ctx = yield* requireSession(threadId);
      return { threadId, turns: ctx.turns };
    });

  const rollbackThread: PiAdapterShape["rollbackThread"] = (threadId, numTurns) =>
    Effect.gen(function* () {
      yield* requireSession(threadId);
      if (!Number.isInteger(numTurns) || numTurns < 1) {
        return yield* new ProviderAdapterValidationError({
          provider: PROVIDER,
          operation: "rollbackThread",
          issue: "numTurns must be an integer >= 1.",
        });
      }
      // Pi forks a session rather than rewinding one in place; there is no
      // command that drops the last N turns from the live session.
      return yield* new ProviderAdapterRequestError({
        provider: PROVIDER,
        method: "thread/rollback",
        detail: "Pi sessions do not support provider-side rollback.",
      });
    });

  const stopSession: PiAdapterShape["stopSession"] = (threadId) =>
    Effect.gen(function* () {
      const ctx = sessions.get(threadId);
      if (!ctx) return;
      yield* stopSessionInternal(ctx);
    });

  const listSessions: PiAdapterShape["listSessions"] = () =>
    Effect.sync(() =>
      Array.from(sessions.values())
        .filter((ctx) => !ctx.stopped)
        .map((ctx) => ({ ...ctx.session })),
    );

  const hasSession: PiAdapterShape["hasSession"] = (threadId) =>
    Effect.sync(() => {
      const ctx = sessions.get(threadId);
      return ctx !== undefined && !ctx.stopped;
    });

  const stopAll: PiAdapterShape["stopAll"] = () =>
    Effect.forEach(Array.from(sessions.values()), (ctx) => stopSessionInternal(ctx), {
      discard: true,
    });

  yield* Effect.addFinalizer(() =>
    Effect.ignore(stopAll()).pipe(Effect.tap(() => PubSub.shutdown(runtimeEventPubSub))),
  );

  return {
    provider: PROVIDER,
    capabilities: {
      // Pi binds its model at spawn (`--model`), so a mid-session switch means
      // a new process; the orchestration layer restarts the session instead.
      sessionModelSwitch: "unsupported",
      supportsConversationRollback: false,
    },
    compaction: { type: "native", start: compactThread },
    startSession,
    sendTurn,
    interruptTurn,
    readThread,
    rollbackThread,
    respondToRequest,
    respondToUserInput,
    stopSession,
    listSessions,
    hasSession,
    stopAll,
    get streamEvents() {
      return Stream.fromPubSub(runtimeEventPubSub);
    },
  } satisfies PiAdapterShape;
});
