import {
  CommandId,
  EventId,
  type OrchestrationEvent,
  type ProviderRuntimeEvent,
  type ThreadId,
  type TurnId,
} from "@t3tools/contracts";
import type { InfinitusFleet, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Deferred from "effect/Deferred";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as FiberHandle from "effect/FiberHandle";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { TurnStartGate } from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { isNotPolled } from "./Infinitus.ts";
import type { InfinitusSessionHoldRelease } from "../Services/InfinitusSessionHold.ts";
import { InfinitusSessionInterrupt } from "../Services/InfinitusSessionInterrupt.ts";
import { CONTINUATION_PROMPT } from "./infinitusResumeOnLimit.logic.ts";
import { fleetProviderForDriver, RELEASE_SPACING_MS } from "./infinitusSessionHold.logic.ts";
import {
  interruptModeOn,
  interruptVerdict,
  PAUSE_MARKER_KIND,
  pauseMarkerSummary,
  RESUME_MARKER_KIND,
  resumeMarkerSummary,
  type ResumeReason,
} from "./infinitusSessionInterrupt.logic.ts";

/** A turn this server started and has not seen end, or one it paused: the
    turn, and the fleet provider its driver spends on. */
interface Tracked {
  readonly turnId: TurnId;
  readonly provider: string;
}

type Input =
  | { readonly kind: "runtime"; readonly event: ProviderRuntimeEvent }
  | { readonly kind: "snapshot"; readonly snapshot: InfinitusSnapshot }
  | { readonly kind: "event"; readonly event: OrchestrationEvent }
  | {
      readonly kind: "resume";
      readonly threadId: ThreadId;
      readonly reply: Deferred.Deferred<InfinitusSessionHoldRelease>;
    };

const WATCHED_EVENTS = new Set<OrchestrationEvent["type"]>([
  "thread.pinned",
  "thread.archived",
  "thread.deleted",
]);

const eventThreadId = (event: OrchestrationEvent): ThreadId | null => {
  const payload = event.payload as { readonly threadId?: unknown };
  return typeof payload.threadId === "string" ? (payload.threadId as ThreadId) : null;
};

/**
 * Session priority mode, interrupt (#743): pauses the background turns already
 * running on a fleet that reads `critical` headroom, and continues them when
 * it reads `abundant`, the thread is pinned, the user says "Resume now", or a
 * real poll carries no verdict any more. The hold layer (#616) keeps new
 * starts from spending; this one stops the spend in flight. Pinned threads
 * are never paused. The verdict is native's, published per fleet; the fork
 * only reads it.
 *
 * Running turns are tracked from the driver's runtime events; while any run
 * and the app says interrupt mode is on (or a fleet already reads critical),
 * or while anything is paused, the layer subscribes to the snapshot — what
 * makes the server poll (#346) — so a server in hold mode or with the mode
 * off pays nothing here. A pause is upstream's own `thread.turn.interrupt`
 * command, so the transcript shows the turn ending as interrupted, plus a
 * marker row naming the fleet; only the turn the thread's session still names
 * is interrupted. A resume continues the thread with upstream's continuation
 * prompt, through `TurnStartGate` like every other start (a fleet still low
 * holds it) — except "Resume now", which runs like the hold's "Run now". Paused
 * turns continue oldest first, spaced by `RELEASE_SPACING_MS`. A thread the
 * user sends into, archives or deletes while paused is forgotten. A server
 * restart forgets paused turns: the transcript still shows the interruption.
 */
export const InfinitusSessionInterruptLive = Layer.effect(
  InfinitusSessionInterrupt,
  Effect.gen(function* () {
    const providerService = yield* ProviderService;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const infinitus = yield* InfinitusService;
    const turnStartGate = yield* TurnStartGate;
    const crypto = yield* Crypto.Crypto;
    const commandId = crypto.randomUUIDv4.pipe(Effect.map(CommandId.make));
    const eventId = crypto.randomUUIDv4.pipe(Effect.map(EventId.make));

    /** Insertion order is age: `paused` continues oldest first. */
    const running = new Map<ThreadId, Tracked>();
    const paused = new Map<ThreadId, Tracked>();
    const watch = yield* FiberHandle.make();

    const shellOf = (threadId: ThreadId) =>
      projectionSnapshotQuery
        .getThreadShellById(threadId)
        .pipe(Effect.option, Effect.map(Option.flatten));

    const appendMarker = (
      threadId: ThreadId,
      kind: string,
      summary: string,
      payload: Record<string, unknown>,
    ) =>
      Effect.gen(function* () {
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        yield* orchestrationEngine.dispatch({
          type: "thread.activity.append",
          commandId: yield* commandId,
          threadId,
          activity: {
            id: yield* eventId,
            tone: "info",
            kind,
            summary,
            payload,
            turnId: null,
            createdAt,
          },
          createdAt,
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.session-interrupt.marker-failed", {
            threadId,
            kind,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    const stopWatching = FiberHandle.clear(watch);
    const startWatching: Effect.Effect<void> = FiberHandle.run(
      watch,
      Stream.runForEach(infinitus.changes(), (snapshot) =>
        worker.enqueue({ kind: "snapshot", snapshot }),
      ),
      { onlyIfMissing: true },
    );
    /** The subscription stands only while it can lead somewhere. */
    const settleWatch = (snapshot: InfinitusSnapshot) =>
      paused.size > 0 || (running.size > 0 && interruptModeOn(snapshot))
        ? startWatching
        : stopWatching;

    /** Interrupts the thread's running turn, if it is still the one the
        session names and the thread is background. */
    const pause = (threadId: ThreadId, entry: Tracked, fleet: InfinitusFleet) =>
      Effect.gen(function* () {
        const shell = yield* shellOf(threadId);
        if (Option.isNone(shell) || shell.value.archivedAt !== null) {
          running.delete(threadId);
          return;
        }
        // Foreground: never paused, but still running — a pin can be lifted.
        if (shell.value.pinnedAt != null) return;
        // Runtime events own `running`: a session that names another turn is
        // projection lag, not a turn that ended. The next reading looks again.
        if (shell.value.session?.activeTurnId !== entry.turnId) return;
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        const interrupted = yield* orchestrationEngine
          .dispatch({
            type: "thread.turn.interrupt",
            commandId: yield* commandId,
            threadId,
            turnId: entry.turnId,
            createdAt,
          })
          .pipe(
            Effect.as(true),
            // Still running: the next reading tries again.
            Effect.catchCause((cause) =>
              Effect.logWarning("infinitus.session-interrupt.interrupt-failed", {
                threadId,
                turnId: entry.turnId,
                cause: Cause.pretty(cause),
              }).pipe(Effect.as(false)),
            ),
          );
        if (!interrupted) return;
        running.delete(threadId);
        paused.set(threadId, entry);
        const headroom = fleet.headroom;
        yield* appendMarker(threadId, PAUSE_MARKER_KIND, pauseMarkerSummary(fleet), {
          fleet: fleet.key,
          provider: fleet.provider,
          turnId: entry.turnId,
          ...(headroom === undefined ? {} : { headroom }),
        });
        yield* Effect.logInfo("infinitus.session-interrupt.paused", {
          threadId,
          turnId: entry.turnId,
          fleet: fleet.key,
        });
      });

    /** The continuation of one paused thread: the marker row, then the send. */
    const continuation = (threadId: ThreadId, entry: Tracked, reason: ResumeReason) =>
      Effect.gen(function* () {
        const shell = yield* shellOf(threadId);
        if (Option.isNone(shell) || shell.value.archivedAt !== null) return;
        yield* appendMarker(
          threadId,
          RESUME_MARKER_KIND,
          resumeMarkerSummary(reason, entry.provider),
          {
            reason,
            provider: entry.provider,
            turnId: entry.turnId,
          },
        );
        yield* providerService.sendTurn({
          threadId,
          input: CONTINUATION_PROMPT,
          interactionMode: shell.value.interactionMode,
        });
        yield* Effect.logInfo("infinitus.session-interrupt.resumed", {
          threadId,
          turnId: entry.turnId,
          reason,
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.session-interrupt.resume-failed", {
            threadId,
            turnId: entry.turnId,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    /** Continues these threads' paused turns, in order, spaced apart. */
    const resume = (threadIds: ReadonlyArray<ThreadId>, reason: ResumeReason) =>
      Effect.gen(function* () {
        let first = true;
        for (const threadId of threadIds) {
          const entry = paused.get(threadId);
          if (entry === undefined) continue;
          if (!first) yield* Effect.sleep(Duration.millis(RELEASE_SPACING_MS));
          first = false;
          // The wait is long enough for the thread to have gone or been sent
          // into; the record goes first so our own turn.started forgets nothing.
          paused.delete(threadId);
          const shell = yield* shellOf(threadId);
          if (Option.isNone(shell) || shell.value.archivedAt !== null) continue;
          if (shell.value.session?.activeTurnId != null) continue;
          const run = continuation(threadId, entry, reason);
          // "Resume now" is the user's word: it runs whatever the fleet reads,
          // like the hold's "Run now". Every other resume is judged like a
          // fresh start — a fleet still low holds it.
          if (reason === "user") yield* run;
          else yield* turnStartGate.start({ threadId, run });
        }
      });

    /** Thread ids in `map` on this provider, oldest first. */
    const threadsOn = (map: ReadonlyMap<ThreadId, Tracked>, provider: string) =>
      [...map].flatMap(([threadId, entry]) => (entry.provider === provider ? [threadId] : []));

    const onSnapshot = (snapshot: InfinitusSnapshot) =>
      Effect.gen(function* () {
        // An app that cannot be reached says nothing: paused turns stay paused.
        // One that answers without a verdict for the fleet (mode turned off,
        // the account swapped) continues them: nobody is judging any more.
        const providers = new Set([...running.values(), ...paused.values()].map((e) => e.provider));
        for (const provider of providers) {
          const verdict = interruptVerdict(snapshot, provider);
          if (verdict.verdict === "interrupt") {
            for (const threadId of threadsOn(running, provider)) {
              yield* pause(threadId, running.get(threadId)!, verdict.fleet);
            }
            continue;
          }
          const reason =
            verdict.verdict === "resume"
              ? "abundant"
              : verdict.verdict === "unknown" && snapshot.available
                ? "off"
                : null;
          if (reason !== null) yield* resume(threadsOn(paused, provider), reason);
        }
        yield* settleWatch(snapshot);
      });

    const onRuntimeEvent = (event: ProviderRuntimeEvent) =>
      Effect.gen(function* () {
        const provider = fleetProviderForDriver(event.provider);
        if (provider === null) return;
        switch (event.type) {
          case "turn.started": {
            if (event.turnId === undefined) return;
            // A new turn on a paused thread is the user moving on (or our own
            // continuation): nothing is paused there any more.
            paused.delete(event.threadId);
            running.set(event.threadId, { turnId: event.turnId, provider });
            // On a server nobody watches, `snapshot` is the pre-poll placeholder
            // until something polls; one refresh reads the socket for real, so
            // interrupt mode arms headlessly too.
            let snapshot = yield* infinitus.snapshot;
            if (isNotPolled(snapshot)) {
              yield* infinitus.refresh;
              snapshot = yield* infinitus.snapshot;
            }
            yield* settleWatch(snapshot);
            return;
          }
          case "turn.completed":
          case "turn.aborted":
            if (
              event.turnId !== undefined &&
              running.get(event.threadId)?.turnId === event.turnId
            ) {
              running.delete(event.threadId);
            }
            break;
          case "session.exited":
            // The session is gone whatever turn it named; the base's turnId is optional.
            running.delete(event.threadId);
            break;
          default:
            return;
        }
        yield* settleWatch(yield* infinitus.snapshot);
      });

    const onInput = (input: Input) =>
      Effect.gen(function* () {
        switch (input.kind) {
          case "runtime":
            return yield* onRuntimeEvent(input.event);
          case "snapshot":
            return yield* onSnapshot(input.snapshot);
          case "event": {
            const threadId = eventThreadId(input.event);
            if (threadId === null) return;
            if (input.event.type === "thread.pinned") {
              yield* resume([threadId], "pinned");
            } else {
              running.delete(threadId);
              paused.delete(threadId);
            }
            yield* settleWatch(yield* infinitus.snapshot);
            return;
          }
          case "resume": {
            const any = paused.has(input.threadId);
            if (any) yield* resume([input.threadId], "user");
            yield* settleWatch(yield* infinitus.snapshot);
            yield* Deferred.succeed(
              input.reply,
              any ? { released: true } : { released: false, reason: "nothing is paused" },
            );
            return;
          }
        }
      });

    const worker = yield* makeDrainableWorker((input: Input) =>
      onInput(input).pipe(
        // One bad input must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.session-interrupt.input-failed", {
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      providerService.streamEvents.pipe(
        // Only what starts or ends a turn; the content stream stays out.
        Stream.filter(
          (event) =>
            event.type === "turn.started" ||
            event.type === "turn.completed" ||
            event.type === "turn.aborted" ||
            event.type === "session.exited",
        ),
        Stream.runForEach((event) => worker.enqueue({ kind: "runtime", event })),
      ),
    );
    yield* forkParked(
      orchestrationEngine.streamDomainEvents.pipe(
        Stream.filter((event) => WATCHED_EVENTS.has(event.type)),
        Stream.runForEach((event) => worker.enqueue({ kind: "event", event })),
      ),
    );

    return InfinitusSessionInterrupt.of({
      resume: (threadId) =>
        Effect.gen(function* () {
          const reply = yield* Deferred.make<InfinitusSessionHoldRelease>();
          yield* worker.enqueue({ kind: "resume", threadId, reply });
          return yield* Deferred.await(reply);
        }),
    });
  }),
);
