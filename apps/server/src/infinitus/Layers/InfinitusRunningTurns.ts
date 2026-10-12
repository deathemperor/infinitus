import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";

/** #829 on orchestrator v2: every active thread whose shell carries an
    `activityRunStatus` — its highest-ordinal run in preparing, starting,
    running or waiting (`ProjectionStore.ts`, `isActivityRunForShell`). A run
    waiting on an approval counts: it dies with the process too. The shell
    names the run only while it is interruptible (`activeRunId`); a waiting
    run answers with the thread's `latestRunId`. A projection read that fails
    is the server's own state gone wrong — die, don't 500. */
export const InfinitusRunningTurnsLive = Layer.effect(
  InfinitusRunningTurns,
  Effect.gen(function* () {
    const projection = yield* ProjectionStore.ProjectionStoreV2;
    return InfinitusRunningTurns.of({
      list: projection.getShellSnapshot({ location: "active" }).pipe(
        Effect.orDie,
        Effect.map((snapshot) =>
          snapshot.threads.flatMap((thread) => {
            if (thread.activityRunStatus == null) return [];
            const turnId = thread.activeRunId ?? thread.latestRunId;
            return turnId === null ? [] : [{ threadId: thread.id, turnId }];
          }),
        ),
      ),
    });
  }),
);
