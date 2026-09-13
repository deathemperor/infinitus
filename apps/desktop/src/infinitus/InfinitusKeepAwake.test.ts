import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import { beforeEach, vi } from "vite-plus/test";

import * as InfinitusKeepAwake from "./InfinitusKeepAwake.ts";

const { blocker } = vi.hoisted(() => ({
  blocker: { start: vi.fn(), stop: vi.fn(), isStarted: vi.fn() },
}));

vi.mock("electron", () => ({ powerSaveBlocker: blocker }));

describe("makeKeepAwake", () => {
  beforeEach(() => {
    blocker.start.mockReset();
    blocker.stop.mockReset();
  });

  it("starts one blocker however often it is asked, and stops it once", () => {
    let next = 7;
    blocker.start.mockImplementation(() => next++);
    const keepAwake = InfinitusKeepAwake.makeKeepAwake(blocker);
    keepAwake.set(true);
    keepAwake.set(true);
    assert.deepStrictEqual(blocker.start.mock.calls, [["prevent-app-suspension"]]);
    assert.isTrue(keepAwake.held);
    keepAwake.set(false);
    keepAwake.set(false);
    assert.deepStrictEqual(blocker.stop.mock.calls, [[7]]);
    assert.isFalse(keepAwake.held);
    keepAwake.set(true);
    keepAwake.set(false);
    assert.deepStrictEqual(blocker.stop.mock.calls, [[7], [8]]);
  });

  it.effect("the layer releases a held blocker when its scope closes", () =>
    Effect.gen(function* () {
      blocker.start.mockReturnValue(3);
      yield* Effect.scoped(
        Effect.gen(function* () {
          const service = yield* InfinitusKeepAwake.InfinitusKeepAwakeService;
          yield* service.set(true);
          assert.deepStrictEqual(blocker.stop.mock.calls, []);
        }).pipe(Effect.provide(InfinitusKeepAwake.layer)),
      );
      assert.deepStrictEqual(blocker.stop.mock.calls, [[3]]);
    }),
  );
});
