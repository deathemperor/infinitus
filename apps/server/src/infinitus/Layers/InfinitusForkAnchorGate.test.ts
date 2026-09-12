import { ThreadId, type ProviderDriverKind } from "@t3tools/contracts";
import { it } from "@effect/vitest";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import { describe, expect } from "vite-plus/test";

import { TurnStartGate } from "../../orchestration/Services/TurnStartGate.ts";
import {
  ProviderSessionDirectory,
  type ProviderRuntimeBinding,
  type ProviderRuntimeBindingWithMetadata,
} from "../../provider/Services/ProviderSessionDirectory.ts";
import { forkCursorAfterRecheck, InfinitusForkAnchorGate } from "./InfinitusForkAnchorGate.ts";

const CLAUDE = "claudeAgent" as ProviderDriverKind;
const sourceId = ThreadId.make("source");
const forkId = ThreadId.make("fork");
const SOURCE_SESSION = "550e8400-e29b-41d4-a716-446655440000";

const forkCursor = {
  threadId: forkId,
  resume: SOURCE_SESSION,
  resumeSessionAt: "assistant-2",
  resumeSessionAtLatest: true,
  fork: true,
};
const sourceCursor = (anchors: ReadonlyArray<string>) => ({
  threadId: sourceId,
  resume: SOURCE_SESSION,
  turnCount: anchors.length,
  anchors: anchors.map((at, index) => ({ turnId: `turn-${index + 1}`, at })),
});

const harness = (sourceAnchors: ReadonlyArray<string>) =>
  Effect.gen(function* () {
    const upserts: Array<ProviderRuntimeBinding> = [];
    let started = 0;
    const bindings: Array<ProviderRuntimeBindingWithMetadata> = [
      {
        threadId: sourceId,
        provider: CLAUDE,
        resumeCursor: sourceCursor(sourceAnchors),
        lastSeenAt: "t",
      },
      { threadId: forkId, provider: CLAUDE, resumeCursor: forkCursor, lastSeenAt: "t" },
    ];
    const layer = InfinitusForkAnchorGate.pipe(
      Layer.provide(
        Layer.mergeAll(
          Layer.succeed(TurnStartGate)({
            start: ({ run }) => run.pipe(Effect.as("started" as const)),
          }),
          Layer.mock(ProviderSessionDirectory)({
            getBinding: (threadId) => {
              const found = bindings.find((b) => b.threadId === threadId);
              return Effect.succeed(found === undefined ? Option.none() : Option.some(found));
            },
            listBindings: () => Effect.succeed(bindings),
            upsert: (binding) =>
              Effect.sync(() => {
                upserts.push(binding);
              }),
          }),
        ),
      ),
    );
    const context = yield* Layer.build(layer);
    const gate = Context.get(context, TurnStartGate);
    const verdict = yield* gate.start({
      threadId: forkId,
      run: Effect.sync(() => {
        started += 1;
      }),
    });
    return { verdict, upserts, started: () => started };
  }).pipe(Effect.scoped);

describe("InfinitusForkAnchorGate (#1013)", () => {
  it.effect(
    "drops the fallback flag when the source completed a turn after the fork was bound",
    () =>
      Effect.gen(function* () {
        const { verdict, upserts, started } = yield* harness([
          "assistant-1",
          "assistant-2",
          "assistant-3",
        ]);
        expect(verdict).toBe("started");
        expect(started()).toBe(1);
        expect(upserts).toHaveLength(1);
        expect(upserts[0]?.resumeCursor).toEqual({
          threadId: forkId,
          resume: SOURCE_SESSION,
          resumeSessionAt: "assistant-2",
          fork: true,
        });
      }),
  );

  it.effect("leaves the binding alone while the fork point is still the source's latest turn", () =>
    Effect.gen(function* () {
      const { verdict, upserts, started } = yield* harness(["assistant-1", "assistant-2"]);
      expect(verdict).toBe("started");
      expect(started()).toBe(1);
      expect(upserts).toHaveLength(0);
    }),
  );

  it("judges only a fork cursor that still carries the flag, and only against a known source", () => {
    expect(
      forkCursorAfterRecheck({ resume: SOURCE_SESSION, fork: true }, [sourceCursor(["x"])]),
    ).toBeNull();
    const otherSource = { resume: "other", anchors: [{ turnId: "t", at: "assistant-9" }] };
    expect(forkCursorAfterRecheck(forkCursor, [otherSource])).toBeNull();
  });
});
