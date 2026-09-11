import { CommandId, EventId, type OrchestrationEvent, type ThreadId } from "@t3tools/contracts";
import type {
  InfinitusFleet,
  InfinitusHeldThread,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
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
import * as SubscriptionRef from "effect/SubscriptionRef";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { TurnStartGate, type TurnStartInput } from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { isNotPolled } from "./Infinitus.ts";
import {
  InfinitusSessionHold,
  type InfinitusSessionHoldRelease,
} from "../Services/InfinitusSessionHold.ts";
import {
  fleetProviderForDriver,
  headroomVerdict,
  HOLD_MARKER_KIND,
  holdMarkerSummary,
  RELEASE_MARKER_KIND,
  RELEASE_SPACING_MS,
  releaseMarkerSummary,
  type ReleaseReason,
} from "./infinitusSessionHold.logic.ts";

/** One start kept for later: the thread, the fleet provider it spends on,
    and the send itself bound to the caller's context, its failures logged. */
interface Held {
  readonly threadId: ThreadId;
  readonly provider: string;
  readonly run: Effect.Effect<void>;
  /** When this start was held, and the hold row's line (#741). */
  readonly since: string;
  readonly summary: string;
}

/** The published view: one entry per thread, oldest first (#741). */
const heldView = (held: ReadonlyArray<Held>): ReadonlyArray<InfinitusHeldThread> => {
  const seen = new Set<ThreadId>();
  const view: InfinitusHeldThread[] = [];
  for (const entry of held) {
    if (seen.has(entry.threadId)) continue;
    seen.add(entry.threadId);
    view.push({ threadId: entry.threadId, since: entry.since, summary: entry.summary });
  }
  return view;
};

type Input =
  | { readonly kind: "hold"; readonly held: Held; readonly fleet: InfinitusFleet }
  | { readonly kind: "snapshot"; readonly snapshot: InfinitusSnapshot }
  | { readonly kind: "event"; readonly event: OrchestrationEvent }
  | {
      readonly kind: "release";
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
 * Session priority mode for the threads this server runs (#616): the
 * `TurnStartGate` that holds a background thread's start while the fleet its
 * driver spends on reads `low` headroom, and runs it when the fleet reads
 * `abundant`, the thread is pinned, the user says "Run now", or a real poll
 * carries no verdict for the fleet any more. Pinned threads are never held; a
 * thread mid-turn is not either (that send is a steer). The verdict is
 * native's, published per fleet; the fork only reads it.
 *
 * Held starts live in memory in arrival order, one marker row per held
 * thread, and the snapshot subscription (what makes the server poll, #346)
 * is held only while something is. Releases run oldest thread first, spaced
 * by `RELEASE_SPACING_MS`, each through the send path it was handed. A
 * thread archived or deleted while held is forgotten. A server restart
 * forgets held starts: the message is still in the thread.
 */
const InfinitusSessionHoldLive = Layer.effect(
  InfinitusSessionHold,
  Effect.gen(function* () {
    const providerService = yield* ProviderService;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const infinitus = yield* InfinitusService;
    const crypto = yield* Crypto.Crypto;
    const commandId = crypto.randomUUIDv4.pipe(Effect.map(CommandId.make));
    const eventId = crypto.randomUUIDv4.pipe(Effect.map(EventId.make));

    let held: ReadonlyArray<Held> = [];
    const published = yield* SubscriptionRef.make<ReadonlyArray<InfinitusHeldThread>>([]);
    /** Every change to `held` goes through here so subscribers see it. */
    const setHeld = (next: ReadonlyArray<Held>) => {
      held = next;
      return SubscriptionRef.set(published, heldView(next));
    };
    const watch = yield* FiberHandle.make();

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
          Effect.logWarning("infinitus.session-hold.marker-failed", {
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

    /** Runs the held starts of these threads, in order, spaced apart. */
    const release = (threadIds: ReadonlyArray<ThreadId>, reason: ReleaseReason) =>
      Effect.gen(function* () {
        let first = true;
        for (const threadId of threadIds) {
          if (!held.some((entry) => entry.threadId === threadId)) continue;
          if (!first) yield* Effect.sleep(Duration.millis(RELEASE_SPACING_MS));
          first = false;
          // The wait is long enough for the thread to have gone: the archive
          // event is queued behind this input, so ask the projection directly.
          const shell = yield* projectionSnapshotQuery
            .getThreadShellById(threadId)
            .pipe(Effect.option, Effect.map(Option.flatten));
          const mine = held.filter((entry) => entry.threadId === threadId);
          yield* setHeld(held.filter((entry) => entry.threadId !== threadId));
          if (Option.isNone(shell) || shell.value.archivedAt !== null) continue;
          const provider = mine[0]!.provider;
          yield* appendMarker(
            threadId,
            RELEASE_MARKER_KIND,
            releaseMarkerSummary(reason, provider),
            {
              reason,
              provider,
              starts: mine.length,
            },
          );
          yield* Effect.logInfo("infinitus.session-hold.released", {
            threadId,
            reason,
            starts: mine.length,
          });
          for (const entry of mine) {
            yield* entry.run;
          }
        }
        if (held.length === 0) yield* stopWatching;
      });

    const forget = (threadId: ThreadId) =>
      Effect.gen(function* () {
        yield* setHeld(held.filter((entry) => entry.threadId !== threadId));
        if (held.length === 0) yield* stopWatching;
      });

    /** Thread ids with a held start, oldest first. */
    const heldThreads = (keep: (entry: Held) => boolean): ReadonlyArray<ThreadId> => {
      const ids: ThreadId[] = [];
      for (const entry of held) {
        if (keep(entry) && !ids.includes(entry.threadId)) ids.push(entry.threadId);
      }
      return ids;
    };

    const onInput = (input: Input): Effect.Effect<void> =>
      Effect.gen(function* () {
        switch (input.kind) {
          case "hold": {
            // A pin that landed while the decision was being read was handled
            // before this hold existed; it releases nothing, so honour it here.
            const shell = yield* projectionSnapshotQuery
              .getThreadShellById(input.held.threadId)
              .pipe(Effect.catchCause(() => Effect.succeed(Option.none())));
            if (Option.isSome(shell) && shell.value.pinnedAt != null) {
              yield* Effect.logInfo("infinitus.session-hold.pinned-meanwhile", {
                threadId: input.held.threadId,
              });
              yield* input.held.run;
              return;
            }
            const first = !held.some((entry) => entry.threadId === input.held.threadId);
            yield* setHeld([...held, input.held]);
            if (first) {
              const headroom = input.fleet.headroom;
              yield* appendMarker(
                input.held.threadId,
                HOLD_MARKER_KIND,
                holdMarkerSummary(input.fleet),
                {
                  fleet: input.fleet.key,
                  provider: input.fleet.provider,
                  ...(headroom === undefined ? {} : { headroom }),
                },
              );
              yield* Effect.logInfo("infinitus.session-hold.held", {
                threadId: input.held.threadId,
                fleet: input.fleet.key,
              });
            }
            yield* startWatching;
            return;
          }
          case "snapshot": {
            // An app that cannot be reached says nothing: the hold stands. One
            // that answers without a verdict for the fleet (mode turned off,
            // the account swapped to one with no usage yet) releases: nobody
            // is judging headroom any more.
            for (const provider of new Set(held.map((entry) => entry.provider))) {
              const verdict = headroomVerdict(input.snapshot, provider).verdict;
              const reason =
                verdict === "release"
                  ? "abundant"
                  : verdict === "unknown" && input.snapshot.available
                    ? "off"
                    : null;
              if (reason === null) continue;
              yield* release(
                heldThreads((entry) => entry.provider === provider),
                reason,
              );
            }
            return;
          }
          case "event": {
            const threadId = eventThreadId(input.event);
            if (threadId === null) return;
            if (input.event.type === "thread.pinned") {
              yield* release([threadId], "pinned");
            } else {
              yield* forget(threadId);
            }
            return;
          }
          case "release": {
            const any = held.some((entry) => entry.threadId === input.threadId);
            if (any) yield* release([input.threadId], "user");
            yield* Deferred.succeed(
              input.reply,
              any ? { released: true } : { released: false, reason: "nothing is held" },
            );
            return;
          }
        }
      });

    const worker = yield* makeDrainableWorker((input: Input) =>
      onInput(input).pipe(
        // One bad input must not end the worker for every later one.
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.session-hold.input-failed", {
            kind: input.kind,
            cause: Cause.pretty(cause),
          }),
        ),
      ),
    );

    yield* forkParked(
      orchestrationEngine.streamDomainEvents.pipe(
        Stream.filter((event) => WATCHED_EVENTS.has(event.type)),
        Stream.runForEach((event) => worker.enqueue({ kind: "event", event })),
      ),
    );

    /** Whether this start waits: the fleet it spends on and the verdict, or
        null for a start that runs now. Anything unreadable runs now — a hold
        is never the safe default. */
    const decide = (threadId: ThreadId, replacesActiveTurn: boolean) =>
      Effect.gen(function* () {
        const shell = yield* projectionSnapshotQuery.getThreadShellById(threadId);
        if (Option.isNone(shell) || shell.value.archivedAt !== null) return null;
        if (shell.value.pinnedAt != null) return null;
        if (!replacesActiveTurn && shell.value.session?.activeTurnId != null) return null;
        const info = yield* providerService.getInstanceInfo(shell.value.modelSelection.instanceId);
        const provider = fleetProviderForDriver(info.driverKind);
        if (provider === null) return null;
        // On a server nobody watches, `snapshot` is the pre-poll placeholder
        // until something polls; one refresh reads the socket for real.
        let snapshot = yield* infinitus.snapshot;
        if (isNotPolled(snapshot)) {
          yield* infinitus.refresh;
          snapshot = yield* infinitus.snapshot;
        }
        const verdict = headroomVerdict(snapshot, provider);
        return verdict.verdict === "hold" ? { provider, fleet: verdict.fleet } : null;
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.session-hold.decide-failed", {
            threadId,
            cause: Cause.pretty(cause),
          }).pipe(Effect.as(null)),
        ),
      );

    return InfinitusSessionHold.of({
      start: <E, R>(input: TurnStartInput<E, R>) =>
        Effect.gen(function* () {
          const decision = yield* decide(input.threadId, input.replacesActiveTurn === true);
          if (decision === null) {
            yield* input.run;
            return "started" as const;
          }
          const context = yield* Effect.context<R>();
          yield* worker.enqueue({
            kind: "hold",
            held: {
              threadId: input.threadId,
              provider: decision.provider,
              since: DateTime.formatIso(yield* DateTime.now),
              summary: holdMarkerSummary(decision.fleet),
              // Run later, nobody awaits the start: its failure is a log line.
              run: input.run.pipe(
                Effect.provideContext(context),
                Effect.catchCause((cause) =>
                  Effect.logWarning("infinitus.session-hold.start-failed", {
                    threadId: input.threadId,
                    cause: Cause.pretty(cause),
                  }),
                ),
              ),
            },
            fleet: decision.fleet,
          });
          return "held" as const;
        }),
      held: SubscriptionRef.changes(published),
      release: (threadId) =>
        Effect.gen(function* () {
          const reply = yield* Deferred.make<InfinitusSessionHoldRelease>();
          yield* worker.enqueue({ kind: "release", threadId, reply });
          return yield* Deferred.await(reply);
        }),
    });
  }),
);

/** The gate the reactor and the startup continuation call, backed by the hold. */
const TurnStartGateFromHold = Layer.effect(
  TurnStartGate,
  Effect.map(InfinitusSessionHold, (hold) => TurnStartGate.of({ start: hold.start })),
);

/** Both services from one instance: the hold, and the gate that is the hold. */
export const InfinitusSessionHoldLayers = Layer.merge(
  InfinitusSessionHoldLive,
  TurnStartGateFromHold.pipe(Layer.provide(InfinitusSessionHoldLive)),
);
