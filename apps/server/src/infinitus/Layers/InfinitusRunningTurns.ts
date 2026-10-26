import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as ProjectionStore from "../../orchestration-v2/ProjectionStore.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";

/** #829 on v2: every active thread whose shell carries an `activityRunStatus` (highest-ordinal run
    preparing, starting, running or waiting; a run waiting on approval counts, it dies with the
    process too). `activeRunId` names the run only while interruptible, else `latestRunId`. A failed
    projection read is the server's own state gone wrong: die, don't 500. */
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
