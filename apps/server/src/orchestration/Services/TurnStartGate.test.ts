import { ThreadId } from "@t3tools/contracts";
import { it as effectIt } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Ref from "effect/Ref";
import { describe, expect } from "vite-plus/test";

import { TurnStartGate, TurnStartGatePassthrough } from "./TurnStartGate.ts";

describe("TurnStartGatePassthrough", () => {
  effectIt.effect("runs every start at once and answers started", () =>
    Effect.gen(function* () {
      const ran = yield* Ref.make(0);
      const gate = yield* TurnStartGate;

      const verdict = yield* gate.start({
        threadId: ThreadId.make("thread-1"),
        run: Ref.update(ran, (count) => count + 1),
      });

      expect(verdict).toBe("started");
      expect(yield* Ref.get(ran)).toBe(1);
    }).pipe(Effect.provide(TurnStartGatePassthrough)),
  );
});
