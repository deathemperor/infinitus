import {
  CommandId,
  MessageId,
  type OrchestrationV2DomainEvent,
  type OrchestrationV2ThreadShell,
  type RunId,
  type ThreadId,
} from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { makeDrainableWorker } from "@infinitus/shared/DrainableWorker";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as FiberHandle from "effect/FiberHandle";
import * as FiberMap from "effect/FiberMap";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";

import type { ClaudeUsageLimitRefusal } from "../../orchestration-v2/Adapters/ClaudeAdapterV2.ts";
import * as Orchestrator from "../../orchestration-v2/Orchestrator.ts";
import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import { forkParked } from "../../serverActivation.ts";
import * as ServerSettings from "../../serverSettings.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusSwapdProbe } from "../Services/InfinitusSwapdProbe.ts";
import {
  CONTINUATION_PROMPT,
  failedStopFromShell,
  limitStopSummary,
  proxyInstanceLabel,
  refusedAccount,
  RESUME_COOLDOWN_MS,
  resumeTarget,
  toWireStop,
  type LimitStop,
  type ResumeTarget,
} from "./infinitusResumeOnLimit.logic.ts";

/** Run ids kept so one stop is never resumed twice; far more than a server
    meets, bounded so the set cannot grow for the process lifetime. */
const RESUMED_LIMIT = 500;
/** Refusals remembered per thread so a parked turn's later failure keeps the
    window the refusal named; bounded the same way. */
const REFUSALS_LIMIT = 500;
/** How long a resume waits for the interrupted parked turn to end before it
    reads the thread again: the adapter closes the CLI and the orchestrator
    records the interrupted run well within this. */
const INTERRUPT_WAIT = "20 seconds";

type Input =
  | { readonly source: "restore" }
  | { readonly source: "refusal"; readonly refusal: ClaudeUsageLimitRefusal }
  | { readonly source: "event"; readonly event: OrchestrationV2DomainEvent }
  | { readonly source: "snapshot"; readonly snapshot: InfinitusSnapshot };

/**
 * Resumes a thread's turn on a live account after a usage limit stopped it
 * (#648), on orchestrator v2 (#1627) — the fork's counterpart to native's
 * terminal nudge. Two things record a stop: the Claude adapter's report of a
 * rejected window on a running turn (`InfinitusLimitStops.refusals`, the
 * parked case: the SDK holds the turn open), and a `run.updated` whose thread
 * shell then reads `lastErrorClass: "usage_limit"` (the failed case: the CLI
 * gave up). Each stop joins the `stopped` list the clients read as the
 * sidebar's "Limited" pill, and is reported to swapd as `limit-hit` for the
 * account whose window the refusal's reset matches (#1486) — never for a
 * proxied instance (#1088), whose limit no account on the Mac lifts. While
 * any plain stop is open the layer subscribes to the Infinitus snapshot (that
 * subscription is what makes the server poll — nothing is stopped, nothing
 * polls) and waits for an account that reads `ok` from a probe taken after
 * the stop with room in the stop's window. Then a parked turn is interrupted
 * (the adapter closes its CLI, which keeps the login it started on for
 * minutes after a swap) and, once the orchestrator records the run as ended,
 * the thread continues with upstream's own continuation prompt as a manual
 * continuation of that run; a failed run is continued the same way at once,
 * its CLI replaced by the adapter on the next prompt. Everything runs through
 * one sequential worker: one record per thread, a stop resumed once, resumes
 * spaced by a cooldown, and a thread that moved on (a newer run, a settle, an
 * archive) is forgotten. The resume itself runs beside the worker, since it
 * waits on an event the worker delivers; it re-reads the thread before each
 * command, so a settle or a user's own send in between stands (#1522). Off
 * by the `infinitusResumeOnLimit` server setting, which keeps the pill and
 * drops the report and the resume.
 */
export const InfinitusResumeOnLimitLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const orchestrator = yield* Orchestrator.OrchestratorV2;
    const projections = yield* ProjectionStore.ProjectionStoreV2;
    const infinitus = yield* InfinitusService;
    const swapd = yield* InfinitusSwapdProbe;
    const settings = yield* ServerSettings.ServerSettingsService;
    const limitStops = yield* InfinitusLimitStops;

    const withBackgroundAccounts = (snapshot: InfinitusSnapshot) =>
      snapshot.available ? Effect.succeed(snapshot) : swapd.snapshot;

    const stops = new Map<ThreadId, LimitStop>();
    /** The last refusal per thread: a parked turn that later fails keeps the
        window its refusal named. */
    const refusals = new Map<ThreadId, ClaudeUsageLimitRefusal>();
    const resumed = new Set<RunId>();
    const lastResumeAt = new Map<ThreadId, number>();
    /** The parked runs a resume has interrupted and waits on. */
    const interrupted = new Map<RunId, Deferred.Deferred<void>>();
    const watch = yield* FiberHandle.make();
    const resumes = yield* FiberMap.make<ThreadId>();

    // Suspended: the list is read when it runs, not when the layer builds.
    const publish = Effect.suspend(() =>
      limitStops.setStopped(
        [...stops.values()]
          .toSorted((left, right) => left.stoppedAt - right.stoppedAt)
          .map(toWireStop),
      ),
    );

    const enabled = settings.getSettings.pipe(
      Effect.map((current) => current.infinitusResumeOnLimit),
      // Unreadable settings never block a resume the user did not turn off.
      Effect.catch(() => Effect.succeed(true)),
    );

    const nowMillis = DateTime.now.pipe(Effect.map(DateTime.toEpochMillis));

    const shellOf = (threadId: ThreadId) =>
      projections.getThreadShell(threadId).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.resume-on-limit.shell-unreadable", {
            threadId,
            cause: Cause.pretty(cause),
          }).pipe(Effect.as(null)),
        ),
      );

    /** The proxied instance the thread runs on (#1088); unreadable settings
        name none. */
    const proxyFor = (shell: Pick<OrchestrationV2ThreadShell, "modelSelection">) =>
      settings.getSettings.pipe(
        Effect.map((current) => proxyInstanceLabel(current.providerInstances, shell.modelSelection)),
        Effect.catch(() => Effect.succeed(null)),
      );

    const remember = <K, V>(map: Map<K, V>, limit: number, key: K, value: V) => {
      map.delete(key);
      if (map.size >= limit) {
        const oldest = map.keys().next().value;
        if (oldest !== undefined) map.delete(oldest);
      }
      map.set(key, value);
    };

    const stopWatching = FiberHandle.clear(watch);
    const startWatching: Effect.Effect<void> = FiberHandle.run(
      watch,
      Stream.runForEach(infinitus.changes(), (snapshot) =>
        worker.enqueue({ source: "snapshot", snapshot }),
      ),
      { onlyIfMissing: true },
    );

    const forget = (threadId: ThreadId) =>
      Effect.gen(function* () {
        if (!stops.delete(threadId)) return;
        yield* publish;
        // A proxy's stop (#1088) waits for nothing here: it keeps no poll alive.
        if (![...stops.values()].some((stop) => stop.proxy === null)) yield* stopWatching;
      });

    /** The stop recorded, published and reported. A repeat of a known stop
        (the SDK re-announcing a parked turn as its reset moves, or a parked
        turn ending the way the CLI ends it) keeps its account and its start,
        takes the newer window, and is not reported again. */
    const record = (
      stop: LimitStop,
      options: { readonly report: boolean },
    ): Effect.Effect<void> =>
      Effect.gen(function* () {
        const known = stops.get(stop.threadId);
        const repeated = known !== undefined && known.runId === stop.runId;
        const next: LimitStop = repeated
          ? {
              ...stop,
              account: known.account,
              fleetKey: known.fleetKey,
              stoppedAt: known.stoppedAt,
              resetsAt: stop.resetsAt ?? known.resetsAt,
              limitType: stop.limitType ?? known.limitType,
            }
          : stop;
        stops.set(next.threadId, next);
        yield* publish;
        yield* Effect.logInfo("infinitus.resume-on-limit.stopped", {
          threadId: next.threadId,
          runId: next.runId,
          kind: next.kind,
          summary: limitStopSummary(next),
          proxy: next.proxy !== null,
        });
        if (next.proxy !== null) return;
        if (!repeated && options.report && next.account !== null && (yield* enabled)) {
          // Quota reads lag refusals by minutes. Report the refusal directly
          // instead of waiting for the usage endpoint to confirm it.
          yield* swapd.reportLimit(
            next.account,
            next.resetsAt === null
              ? null
              : DateTime.formatIso(DateTime.makeUnsafe(next.resetsAt)),
          );
        }
        yield* startWatching;
      });

    const onRefusal = (refusal: ClaudeUsageLimitRefusal) =>
      Effect.gen(function* () {
        remember(refusals, REFUSALS_LIMIT, refusal.threadId, refusal);
        if (resumed.has(refusal.runId)) return;
        const shell = yield* shellOf(refusal.threadId);
        // A settled thread's parked turn can still refuse; nobody waits on it.
        if (shell === null || shell.archivedAt !== null || shell.settledOverride === "settled")
          return;
        const now = yield* nowMillis;
        const proxy = yield* proxyFor(shell);
        const base = {
          threadId: refusal.threadId,
          runId: refusal.runId,
          kind: "parked" as const,
          stoppedAt: now,
          resetsAt: refusal.resetsAt,
          limitType: refusal.rateLimitType,
        };
        if (proxy !== null) {
          return yield* record(
            { ...base, fleetKey: null, account: null, proxy },
            { report: false },
          );
        }
        const accounts = yield* withBackgroundAccounts(yield* infinitus.snapshot);
        const refused = refusedAccount(refusal, accounts);
        yield* record(
          {
            ...base,
            fleetKey: refused?.fleetKey ?? null,
            account: refused?.account ?? null,
            proxy: null,
          },
          { report: true },
        );
      });

    const onEvent = (event: OrchestrationV2DomainEvent) =>
      Effect.gen(function* () {
        const threadId = event.threadId;
        if (threadId === undefined) return;
        switch (event.type) {
          case "thread.settled":
          case "thread.archived":
          case "thread.deleted":
            return yield* forget(threadId);
          case "run.updated": {
            const run = event.payload;
            const waiting = interrupted.get(run.id);
            if (
              waiting !== undefined &&
              (run.status === "interrupted" ||
                run.status === "failed" ||
                run.status === "completed" ||
                run.status === "cancelled")
            ) {
              yield* Deferred.succeed(waiting, undefined);
            }
            const known = stops.get(threadId);
            if (run.status === "failed") {
              if (resumed.has(run.id)) return;
              const shell = yield* shellOf(threadId);
              if (shell === null) return;
              const refusal = refusals.get(threadId) ?? null;
              const failed = failedStopFromShell(shell, yield* nowMillis, refusal);
              if (failed === null || failed.runId !== run.id) {
                // A run that failed for another reason moves the thread on.
                if (known !== undefined && known.runId !== run.id) yield* forget(threadId);
                return;
              }
              if (known !== undefined && known.runId === run.id) {
                // A parked turn ending the way the CLI ends it: one stop, the
                // window kept, nothing reported twice.
                return yield* record({ ...known, ...failed, kind: "failed" }, { report: false });
              }
              const proxy = yield* proxyFor(shell);
              if (proxy !== null) {
                return yield* record(
                  { ...failed, fleetKey: null, account: null, proxy },
                  { report: false },
                );
              }
              const accounts = yield* withBackgroundAccounts(yield* infinitus.snapshot);
              const refused = refusedAccount(
                refusal !== null && refusal.runId === run.id
                  ? refusal
                  : { rateLimitType: null, resetsAt: failed.resetsAt },
                accounts,
              );
              return yield* record(
                {
                  ...failed,
                  fleetKey: refused?.fleetKey ?? null,
                  account: refused?.account ?? null,
                  proxy: null,
                },
                { report: true },
              );
            }
            if (known === undefined) return;
            if (known.runId !== run.id) {
              // Another run on the thread: the user sent again, or the
              // continuation went. The stop is no longer ours.
              if (run.status !== "queued") yield* forget(threadId);
              return;
            }
            // The stop's own run ended some other way: a parked turn that
            // completed did so on its own, or the user interrupted it.
            if (
              run.status === "completed" ||
              run.status === "interrupted" ||
              run.status === "cancelled"
            ) {
              yield* forget(threadId);
            }
            return;
          }
          default:
            return;
        }
      });

    /** The replace-then-send, beside the worker: the interrupted run's end
        arrives through the worker, so waiting for it there would wait on
        itself. Each command re-reads the thread first, so a settle, an
        archive or the user's own send since the stop stands (#1522). */
    const resume = (stop: LimitStop, target: ResumeTarget) =>
      Effect.gen(function* () {
        const resumedAt = yield* nowMillis;
        const stillOurs = (shell: OrchestrationV2ThreadShell | null, parkedRunActive: boolean) =>
          shell !== null &&
          shell.archivedAt === null &&
          shell.settledOverride !== "settled" &&
          shell.latestRunId === stop.runId &&
          (parkedRunActive ? shell.activeRunId === stop.runId : shell.activeRunId === null);
        if (stop.kind === "parked") {
          if (!stillOurs(yield* shellOf(stop.threadId), true)) {
            return yield* Effect.logInfo("infinitus.resume-on-limit.overtaken", {
              threadId: stop.threadId,
              runId: stop.runId,
            });
          }
          // The resumed turn always runs in a fresh CLI: the adapter closes the
          // query on interrupt, and a live process can keep spending the
          // account it started on for minutes after the swap.
          const ended = yield* Deferred.make<void>();
          interrupted.set(stop.runId, ended);
          yield* orchestrator
            .dispatch({
              type: "run.interrupt",
              commandId: CommandId.make(`limit-resume-interrupt:${stop.runId}:${resumedAt}`),
              threadId: stop.threadId,
              runId: stop.runId,
              reason: `Usage limit: resuming on ${target.account}`,
            })
            .pipe(
              Effect.andThen(Deferred.await(ended).pipe(Effect.timeoutOption(INTERRUPT_WAIT))),
              Effect.ensuring(Effect.sync(() => interrupted.delete(stop.runId))),
            );
        }
        if (!stillOurs(yield* shellOf(stop.threadId), false)) {
          return yield* Effect.logInfo("infinitus.resume-on-limit.overtaken", {
            threadId: stop.threadId,
            runId: stop.runId,
          });
        }
        yield* orchestrator.dispatch({
          type: "message.dispatch",
          commandId: CommandId.make(`limit-resume:${stop.runId}:${resumedAt}`),
          messageId: MessageId.make(`limit-resume:${stop.runId}:${resumedAt}`),
          threadId: stop.threadId,
          manualContinuationOfRunId: stop.runId,
          text: CONTINUATION_PROMPT,
          attachments: [],
          dispatchMode: { type: "start_immediately" },
          createdBy: "user",
          creationSource: "server",
        });
        yield* Effect.logInfo("infinitus.resume-on-limit.resumed", {
          threadId: stop.threadId,
          runId: stop.runId,
          account: target.account,
          from: target.from,
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.resume-on-limit.failed", {
            threadId: stop.threadId,
            runId: stop.runId,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    const onSnapshot = (snapshot: InfinitusSnapshot) =>
      Effect.gen(function* () {
        if (![...stops.values()].some((stop) => stop.proxy === null)) return;
        const accounts = yield* withBackgroundAccounts(snapshot);
        const now = yield* nowMillis;
        for (const stop of [...stops.values()]) {
          const target = resumeTarget(stop, accounts, now);
          if (target === null) continue;
          const last = lastResumeAt.get(stop.threadId);
          if (last !== undefined && now - last < RESUME_COOLDOWN_MS) continue;
          if (!(yield* enabled)) continue;
          // Claimed here, on the worker, so a refusal or a failure landing
          // while the resume runs cannot record the same run again.
          if (resumed.size >= RESUMED_LIMIT) {
            const oldest = resumed.values().next().value;
            if (oldest !== undefined) resumed.delete(oldest);
          }
          resumed.add(stop.runId);
          lastResumeAt.set(stop.threadId, now);
          yield* forget(stop.threadId);
          yield* FiberMap.run(resumes, stop.threadId)(resume(stop, target));
        }
      });

    const restore = Effect.gen(function* () {
      const snapshot = yield* projections.getShellSnapshot();
      const now = yield* nowMillis;
      for (const shell of snapshot.threads) {
        const failed = failedStopFromShell(shell, now, null);
        if (failed === null) continue;
        const proxy = yield* proxyFor(shell);
        // The account the stop was on is not persisted; the next probe's
        // reading of the window decides, as it does for a stop with no name.
        stops.set(shell.id, { ...failed, fleetKey: null, account: null, proxy });
      }
      if (stops.size === 0) return;
      yield* publish;
      yield* Effect.logInfo("infinitus.resume-on-limit.restored", { count: stops.size });
      if ([...stops.values()].some((stop) => stop.proxy === null)) yield* startWatching;
    });

    const worker = yield* makeDrainableWorker((input: Input) =>
      (input.source === "restore"
        ? restore
        : input.source === "refusal"
          ? onRefusal(input.refusal)
          : input.source === "event"
            ? onEvent(input.event)
            : onSnapshot(input.snapshot)
      ).pipe(
        // One bad input must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.resume-on-limit.input-failed", {
            source: input.source,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      Effect.andThen(
        worker.enqueue({ source: "restore" }),
        orchestrator.streamDomainEvents.pipe(
          // The live tail only (no replay from genesis); what can record or
          // cancel a stop, and nothing else, reaches the worker.
          Stream.runForEach((event) =>
            event.type === "run.updated" ||
            event.type === "thread.settled" ||
            event.type === "thread.archived" ||
            event.type === "thread.deleted"
              ? worker.enqueue({ source: "event", event })
              : Effect.void,
          ),
          Effect.catchCause((cause) =>
            Effect.logWarning("infinitus.resume-on-limit.stream-ended", {
              cause: Cause.pretty(cause),
            }),
          ),
        ),
      ),
    );
    yield* forkParked(
      Stream.runForEach(limitStops.refusals, (refusal) =>
        worker.enqueue({ source: "refusal", refusal }),
      ),
    );
  }),
);
