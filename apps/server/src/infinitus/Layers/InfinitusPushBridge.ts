import type { OrchestrationEvent, ThreadId } from "@t3tools/contracts";
import { projectThreadAwareness, type AgentAwarenessPhase } from "@t3tools/shared/agentAwareness";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";

import * as ServerEnvironment from "../../environment/ServerEnvironment.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import {
  eventThreadId,
  shouldPublishAgentAwarenessEvent,
} from "../../relay/AgentAwarenessRelay.ts";
import { forkParked } from "../../serverActivation.ts";
import { ServerSettingsService } from "../../serverSettings.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusControlClient } from "../Services/InfinitusControlClient.ts";
import { NOT_POLLED_REASON } from "./Infinitus.ts";
import {
  manifestHasPush,
  shouldPushPhase,
  threadPhasePayload,
} from "./infinitusPushBridge.logic.ts";

/**
 * Fork (#269 G): the push bridge. The thread phases the relay's awareness
 * ladder already derives (`projectThreadAwareness`, what the phone's Live
 * Activity draws) are handed to the Mac's `push` verb when a thread moves
 * into one a person acts on — waiting for approval, waiting for input,
 * finished, failed — and the Mac fans them out the way it does its own
 * account events: the Notification Center, the phone's alert token, Slack
 * and Telegram. Nothing new on the wire: one verb the manifest lists with
 * `stdin: "payload"`, the JSON on the request line's `secret` field where
 * stdin material always travels, through the control client directly (the
 * `command` path is secret-free and polls after every write).
 *
 * Off by default (`infinitusPushBridge`): the desktop already posts its own
 * banner for these phases (#270 B), and the Mac's `push` also posts one, so
 * a Mac running both would see two per approval. The setting is for the
 * away channels. Each event's phase is recorded per thread before the
 * socket call, first sighting silently, so a restart announces nothing and
 * the same phase is never pushed twice; an unreachable Mac drops the push.
 * Only thread ids and phases reach the log; never a title.
 */
export const InfinitusPushBridgeLive = Layer.effectDiscard(
  Effect.gen(function* () {
    const settings = yield* ServerSettingsService;
    const infinitus = yield* InfinitusService;
    const control = yield* InfinitusControlClient;
    const orchestrationEngine = yield* OrchestrationEngineService;
    const projectionSnapshotQuery = yield* ProjectionSnapshotQuery;
    const environmentId = yield* (yield* ServerEnvironment.ServerEnvironment).getEnvironmentId;
    const phases = new Map<ThreadId, AgentAwarenessPhase>();

    const enabled = settings.getSettings.pipe(
      Effect.map((current) => current.infinitusPushBridge),
      Effect.orElseSucceed(() => false),
    );

    // The snapshot answers the last poll and nobody polls a headless server:
    // an unpolled placeholder is refreshed once so the manifest gate can open.
    const manifestReady = Effect.gen(function* () {
      let snapshot = yield* infinitus.snapshot;
      if (!snapshot.available && snapshot.unavailableReason === NOT_POLLED_REASON) {
        yield* infinitus.refresh;
        snapshot = yield* infinitus.snapshot;
      }
      return snapshot.available && manifestHasPush(snapshot.commands);
    });

    const awarenessOf = (threadId: ThreadId) =>
      Effect.gen(function* () {
        const thread = yield* projectionSnapshotQuery.getThreadShellById(threadId);
        if (Option.isNone(thread)) return null;
        const project = yield* projectionSnapshotQuery.getProjectShellById(thread.value.projectId);
        if (Option.isNone(project)) return null;
        return projectThreadAwareness({
          environmentId,
          project: project.value,
          thread: thread.value,
        });
      });

    const push = (threadId: ThreadId, title: string, phase: AgentAwarenessPhase) =>
      control
        .request({ command: "push", secret: threadPhasePayload({ threadId, title, phase }) })
        .pipe(
          Effect.asVoid,
          Effect.tap(() => Effect.logDebug("infinitus.push-bridge.pushed", { threadId, phase })),
          Effect.catchTags({
            InfinitusUnavailable: () =>
              Effect.logDebug("infinitus.push-bridge.unavailable", { threadId, phase }),
            InfinitusProtocolError: (error) =>
              Effect.logWarning("infinitus.push-bridge.refused", { detail: error.detail }),
            InfinitusCommandFailed: (error) =>
              Effect.logWarning("infinitus.push-bridge.refused", { error: error.error }),
          }),
        );

    const onEvent = (event: OrchestrationEvent) =>
      Effect.gen(function* () {
        const threadId = eventThreadId(event);
        if (threadId === null || !shouldPublishAgentAwarenessEvent(event)) return;
        const state = yield* awarenessOf(threadId);
        if (state === null) {
          // Deleted, or a thread with no phase yet: nothing to remember.
          phases.delete(threadId);
          return;
        }
        const previous = phases.get(threadId);
        phases.set(threadId, state.phase);
        if (!shouldPushPhase(previous, state.phase)) return;
        if (!(yield* enabled)) return;
        if (!(yield* manifestReady)) return;
        yield* push(threadId, state.threadTitle, state.phase);
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.push-bridge.event-failed", {
            type: event.type,
            cause: Cause.pretty(cause),
          }),
        ),
      );

    // Sequential on purpose: the phase map is written before the socket call,
    // so a burst of events for one thread pushes each phase once.
    yield* forkParked(orchestrationEngine.streamDomainEvents.pipe(Stream.runForEach(onEvent)));
  }),
);
