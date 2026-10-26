import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Ref from "effect/Ref";

import * as ServerSettings from "../serverSettings.ts";
import * as ProjectionStore from "./ProjectionStore.ts";
import {
  WORKTREE_CAP_SUGGESTIONS,
  WorktreeCapRefusalError,
  worktreeCapRefusal,
} from "./worktreeCap.logic.ts";

/**
 * Worktree limit (#269 H): the gate a launch passes before creating a worktree. A reservation
 * counts against launches started in the same instant (a multi-model send) until the projection
 * records the worktree or the launch gives up, so a batch cannot land over the limit. The verdict
 * is `worktreeCapRefusal`.
 */
export class WorktreeCapGate extends Context.Service<
  WorktreeCapGate,
  {
    /**
     * Reserves a slot for the worktree a launch is about to create, or fails
     * with the refusal. The returned effect releases the slot; it is
     * idempotent, so a launch may release early once the projection counts
     * the worktree and again when it ends.
     */
    readonly reserve: Effect.Effect<Effect.Effect<void>, WorktreeCapRefusalError>;
  }
>()("t3/orchestration-v2/WorktreeCap/WorktreeCapGate") {}

const make = Effect.gen(function* () {
  const serverSettings = yield* ServerSettings.ServerSettingsService;
  const projectionStore = yield* ProjectionStore.ProjectionStoreV2;
  const inFlight = yield* Ref.make(0);

  const reserve: WorktreeCapGate["Service"]["reserve"] = Effect.gen(function* () {
    // The slot is taken before any read so that launches started together
    // see each other, whichever reads first.
    const others = yield* Ref.modify(inFlight, (count) => [count, count + 1] as const);
    let released = false;
    const release = Effect.suspend(() => {
      if (released) return Effect.void;
      released = true;
      return Ref.update(inFlight, (count) => count - 1);
    });
    const refusal = yield* Effect.gen(function* () {
      const { worktreeMaxCount } = yield* serverSettings.getSettings;
      if (worktreeMaxCount <= 0) return null;
      const holders = yield* projectionStore.getWorktreeHolders(WORKTREE_CAP_SUGGESTIONS);
      return worktreeCapRefusal(holders, worktreeMaxCount, others);
    }).pipe(
      // A failed settings or projection read lets the worktree through
      // rather than blocking every launch on the server.
      Effect.catchCause((cause) =>
        Effect.logWarning("Worktree limit check failed; allowing the worktree", { cause }).pipe(
          Effect.as(null),
        ),
      ),
      Effect.onInterrupt(() => release),
    );
    if (refusal !== null) {
      yield* release;
      return yield* Effect.fail(new WorktreeCapRefusalError(refusal));
    }
    return release;
  });

  return { reserve } satisfies WorktreeCapGate["Service"];
});

export const layer = Layer.effect(WorktreeCapGate, make);
