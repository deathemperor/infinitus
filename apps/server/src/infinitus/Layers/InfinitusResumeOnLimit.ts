import {
  CommandId,
  EventId,
  type ProviderRuntimeEvent,
  type ThreadId,
  type TurnId,
} from "@t3tools/contracts";
import type { InfinitusHeldThread, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FiberHandle from "effect/FiberHandle";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";
import { makeDrainableWorker } from "@t3tools/shared/DrainableWorker";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { TurnStartGate } from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { forkParked } from "../../serverActivation.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import {
  CONTINUATION_PROMPT,
  eventCancelsStop,
  LIMIT_MARKER_KIND,
  limitMarkerSummary,
  limitStopFromEvent,
  RESUME_COOLDOWN_MS,
  RESUME_MARKER_KIND,
  resumeMarkerSummary,
  resumeTarget,
  type LimitStop,
  type ResumeTarget,
} from "./infinitusResumeOnLimit.logic.ts";

/** Stop turn ids kept so one stop is never resumed twice; far more than a
    server meets, bounded so the set cannot grow for the process lifetime. */
const RESUMED_LIMIT = 500;

type Input =
  | { readonly source: "runtime"; readonly event: ProviderRuntimeEvent }
  | { readonly source: "snapshot"; readonly snapshot: InfinitusSnapshot };

/**
 * Resumes a thread's turn on a live account after a usage limit stopped it
 * (#648) — the fork's counterpart to native's terminal nudge. Watches the
 * Claude driver's runtime events for a limit stop; while any thread is
 * stopped, subscribes to the Infinitus snapshot (that subscription is what
 * makes the server poll — nothing is stopped, nothing polls) and waits for an
 * account that reads `ok` from a probe taken after the stop. Then: the parked
 * turn is interrupted (a turn sent into a parked one only steers it), a marker
 * row names the account, and the thread continues with upstream's own
 * continuation prompt from its persisted resume cursor — Claude picks the same
 * transcript up on the new credentials. Everything runs through one sequential
 * worker: one record per thread, a stop resumed once, resumes spaced by a
 * cooldown, and a turn the user moved on from is forgotten. Off by the
 * `infinitusResumeOnLimit` server setting. Each stop also leaves an
 * `infinitus.thread.limited` row and joins the `stopped` list the sidebar
 * reads (#270 I), until it resumes or is forgotten.
 */
const resetsAtIso = (stop: LimitStop): string | null =>
  stop.resetsAt === null ? null : DateTime.formatIso(DateTime.makeUnsafe(stop.resetsAt));

export const InfinitusResumeOnLimitLive = Layer.effect(
  InfinitusLimitStops,
  Effect.gen(function* () {
    const providerService = yield* ProviderService;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const infinitus = yield* InfinitusService;
    const settings = yield* ServerSettingsService;
    const turnStartGate = yield* TurnStartGate;
    const crypto = yield* Crypto.Crypto;
    const randomUUID = crypto.randomUUIDv4;
    const commandId = randomUUID.pipe(Effect.map(CommandId.make));
    const eventId = randomUUID.pipe(Effect.map(EventId.make));

    const stops = new Map<ThreadId, LimitStop>();
    /** What the sidebar sees of `stops`: one entry per stopped thread. */
    const stopped = yield* SubscriptionRef.make<ReadonlyArray<InfinitusHeldThread>>([]);
    const marks = new Map<ThreadId, InfinitusHeldThread>();
    // Suspended: the list is read when it runs, not when the layer builds.
    const publish = Effect.suspend(() => SubscriptionRef.set(stopped, [...marks.values()]));
    const resumed = new Set<TurnId>();
    const lastResumeAt = new Map<ThreadId, number>();
    const watch = yield* FiberHandle.make();

    const enabled = settings.getSettings.pipe(
      Effect.map((current) => current.infinitusResumeOnLimit),
      // Unreadable settings never block a resume the user did not turn off.
      Effect.catch(() => Effect.succeed(true)),
    );

    const nowMillis = DateTime.now.pipe(Effect.map(DateTime.toEpochMillis));

    const resume = Effect.fn("Infinitus.resumeOnLimit")(function* (
      stop: LimitStop,
      target: ResumeTarget,
    ) {
      const shell = yield* projectionSnapshotQuery.getThreadShellById(stop.threadId);
      if (Option.isNone(shell) || shell.value.archivedAt !== null) return;
      const context = yield* projectionSnapshotQuery.getThreadRuntimeContext(stop.threadId);
      if (Option.isNone(context) || context.value.session === null) return;
      if (stop.kind === "parked") {
        yield* providerService.interruptTurn({
          threadId: stop.threadId,
          ...(stop.turnId === null ? {} : { turnId: stop.turnId }),
        });
      }
      const createdAt = DateTime.formatIso(yield* DateTime.now);
      yield* orchestrationEngine.dispatch({
        type: "thread.activity.append",
        commandId: yield* commandId,
        threadId: stop.threadId,
        activity: {
          id: yield* eventId,
          tone: "info",
          kind: RESUME_MARKER_KIND,
          summary: resumeMarkerSummary(target),
          payload: {
            fleet: target.fleetKey,
            from: target.from,
            to: target.account,
            turnId: stop.turnId,
            stop: stop.kind,
          },
          turnId: stop.turnId,
          createdAt,
        },
        createdAt,
      });
      yield* orchestrationEngine.dispatch({
        type: "thread.session.set",
        commandId: yield* commandId,
        threadId: stop.threadId,
        session: {
          ...context.value.session,
          status: "starting",
          activeTurnId: null,
          lastError: null,
          updatedAt: createdAt,
        },
        createdAt,
      });
      yield* providerService.sendTurn({
        threadId: stop.threadId,
        input: CONTINUATION_PROMPT,
        interactionMode: shell.value.interactionMode,
      });
      yield* Effect.logInfo("infinitus.resume-on-limit.resumed", {
        threadId: stop.threadId,
        turnId: stop.turnId,
        account: target.account,
        from: target.from,
      });
    });

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
        stops.delete(threadId);
        if (marks.delete(threadId)) yield* publish;
        if (stops.size === 0) yield* stopWatching;
      });

    /** The row and the sidebar entry a stop leaves the moment it lands. */
    const mark = (stop: LimitStop) =>
      Effect.gen(function* () {
        const createdAt = DateTime.formatIso(yield* DateTime.now);
        const summary = limitMarkerSummary(stop);
        const resetsAt = resetsAtIso(stop);
        marks.set(stop.threadId, {
          threadId: stop.threadId,
          since: createdAt,
          summary,
          kind: "limited",
          ...(resetsAt === null ? {} : { resetsAt }),
        });
        yield* publish;
        yield* orchestrationEngine.dispatch({
          type: "thread.activity.append",
          commandId: yield* commandId,
          threadId: stop.threadId,
          activity: {
            id: yield* eventId,
            tone: "info",
            kind: LIMIT_MARKER_KIND,
            summary,
            payload: {
              turnId: stop.turnId,
              stop: stop.kind,
              accounts: [...stop.activeAtStop.values()],
              resetsAt,
            },
            turnId: stop.turnId,
            createdAt,
          },
          createdAt,
        });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.resume-on-limit.marker-failed", {
            threadId: stop.threadId,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    /** The SDK re-announces a parked turn as its reset advances: the stream
        entry follows (the sidebar's tooltip is live), the row stays as written. */
    const remark = (stop: LimitStop) =>
      Effect.suspend(() => {
        const entry = marks.get(stop.threadId);
        if (entry === undefined) return Effect.void;
        const resetsAt = resetsAtIso(stop);
        const { resetsAt: _dropped, ...rest } = entry;
        marks.set(stop.threadId, { ...rest, ...(resetsAt === null ? {} : { resetsAt }) });
        return publish;
      });

    const onRuntimeEvent = (event: ProviderRuntimeEvent): Effect.Effect<void> =>
      Effect.gen(function* () {
        const existing = stops.get(event.threadId);
        if (existing !== undefined && eventCancelsStop(event, existing)) {
          yield* forget(event.threadId);
        }
        const snapshot = yield* infinitus.snapshot;
        const stop = limitStopFromEvent(event, yield* nowMillis, snapshot);
        if (stop === null) return;
        if (stop.turnId !== null && resumed.has(stop.turnId)) return;
        const known = stops.get(stop.threadId);
        stops.set(stop.threadId, stop);
        if (known === undefined) yield* mark(stop);
        else if (known.resetsAt !== stop.resetsAt) yield* remark(stop);
        yield* Effect.logInfo("infinitus.resume-on-limit.stopped", {
          threadId: stop.threadId,
          turnId: stop.turnId,
          kind: stop.kind,
        });
        yield* startWatching;
      });

    const onSnapshot = (snapshot: InfinitusSnapshot): Effect.Effect<void> =>
      Effect.gen(function* () {
        const now = yield* nowMillis;
        for (const stop of stops.values()) {
          const target = resumeTarget(stop, snapshot);
          if (target === null) continue;
          const last = lastResumeAt.get(stop.threadId);
          if (last !== undefined && now - last < RESUME_COOLDOWN_MS) continue;
          if (!(yield* enabled)) {
            yield* forget(stop.threadId);
            continue;
          }
          // The record goes before anything is sent: a second tick cannot
          // resume the same stop, and our own interrupt cannot cancel it.
          yield* forget(stop.threadId);
          if (stop.turnId !== null) {
            resumed.add(stop.turnId);
            if (resumed.size > RESUMED_LIMIT) {
              const oldest = resumed.values().next().value;
              if (oldest !== undefined) resumed.delete(oldest);
            }
          }
          lastResumeAt.set(stop.threadId, now);
          // Fork (#616): a background thread's resume waits with the gate while
          // its fleet reads low; run later, it resumes on the account live then.
          yield* turnStartGate.start({
            threadId: stop.threadId,
            replacesActiveTurn: stop.kind === "parked",
            run: Effect.gen(function* () {
              const current = resumeTarget(stop, yield* infinitus.snapshot) ?? target;
              yield* resume(stop, current);
            }).pipe(
              Effect.catchCause((cause) =>
                Effect.logWarning("infinitus.resume-on-limit.failed", {
                  threadId: stop.threadId,
                  turnId: stop.turnId,
                  cause: Cause.pretty(cause),
                }),
              ),
            ),
          });
        }
      });

    const worker = yield* makeDrainableWorker((input: Input) =>
      (input.source === "runtime" ? onRuntimeEvent(input.event) : onSnapshot(input.snapshot)).pipe(
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
      providerService.streamEvents.pipe(
        // Only what can record or cancel a stop; the content stream stays out.
        Stream.filter(
          (event) =>
            event.type === "runtime.warning" ||
            event.type === "turn.started" ||
            event.type === "turn.completed" ||
            event.type === "turn.aborted" ||
            event.type === "session.exited",
        ),
        Stream.runForEach((event) => worker.enqueue({ source: "runtime", event })),
      ),
    );

    return InfinitusLimitStops.of({ stopped: SubscriptionRef.changes(stopped) });
  }),
);
