import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { InfinitusKeepAwakeService } from "../../infinitus/InfinitusKeepAwake.ts";
import { setKeepAwake } from "./infinitus.ts";

describe("setKeepAwake", () => {
  it.effect("hands the renderer's verdict to the keep-awake service", () =>
    Effect.gen(function* () {
      const calls: Array<boolean> = [];
      const layer = Layer.succeed(
        InfinitusKeepAwakeService,
        InfinitusKeepAwakeService.of({
          set: (active) =>
            Effect.sync(() => {
              calls.push(active);
            }),
        }),
      );
      yield* setKeepAwake.handler(true).pipe(Effect.provide(layer));
      yield* setKeepAwake.handler(false).pipe(Effect.provide(layer));
      assert.deepStrictEqual(calls, [true, false]);
    }),
  );
});
