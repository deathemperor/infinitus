import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import type * as EffectAcpSchema from "effect-acp/schema";

import {
  applyOmpAcpModelSelection,
  buildOmpAcpSpawnInput,
  isBareSlashCommand,
  OMP_DEFAULT_MODEL_SLUG,
} from "./OmpAcpSupport.ts";

const ompConfigOptions: ReadonlyArray<EffectAcpSchema.SessionConfigOption> = [
  {
    id: "mode",
    name: "Mode",
    category: "mode",
    type: "select",
    currentValue: "default",
    options: [
      { value: "default", name: "Default" },
      { value: "plan", name: "Plan" },
    ],
  },
  {
    id: "model",
    name: "Model",
    category: "model",
    type: "select",
    currentValue: "google-antigravity/gemini-3.1-pro",
    options: [
      { value: "google-antigravity/gemini-3.1-pro", name: "Gemini 3.1 Pro" },
      { value: "google-antigravity/claude-sonnet-4-6", name: "Claude Sonnet 4.6" },
    ],
  },
  {
    id: "thinking",
    name: "Thinking",
    category: "thought_level",
    type: "select",
    currentValue: "medium",
    options: [
      { value: "low", name: "Low" },
      { value: "medium", name: "Medium" },
      { value: "high", name: "High" },
    ],
  },
];

describe("buildOmpAcpSpawnInput", () => {
  it("builds the default Oh My Pi ACP command", () => {
    expect(buildOmpAcpSpawnInput(undefined, "/tmp/project")).toEqual({
      command: "omp",
      args: ["--no-title", "acp"],
      cwd: "/tmp/project",
    });
  });

  it("uses the configured binary path", () => {
    expect(buildOmpAcpSpawnInput({ binaryPath: "/usr/local/bin/omp" }, "/tmp/project")).toEqual({
      command: "/usr/local/bin/omp",
      args: ["--no-title", "acp"],
      cwd: "/tmp/project",
    });
  });

  it("forwards --yolo only in full-access mode, with acp last", () => {
    expect(buildOmpAcpSpawnInput(undefined, "/tmp/project", undefined, "full-access")).toEqual({
      command: "omp",
      args: ["--no-title", "--yolo", "acp"],
      cwd: "/tmp/project",
    });
  });

  it.each(["approval-required", "auto-accept-edits", "auto"] as const)(
    "does not pass --yolo in %s mode",
    (runtimeMode) => {
      expect(buildOmpAcpSpawnInput(undefined, "/tmp/project", undefined, runtimeMode)).toEqual({
        command: "omp",
        args: ["--no-title", "acp"],
        cwd: "/tmp/project",
      });
    },
  );
});

describe("applyOmpAcpModelSelection", () => {
  const makeRuntime = (options = ompConfigOptions) => {
    const calls: Array<{ readonly configId: string; readonly value: string | boolean }> = [];
    return {
      calls,
      runtime: {
        getConfigOptions: Effect.succeed(options),
        setConfigOption: (configId: string, value: string | boolean) =>
          Effect.sync(() => {
            calls.push({ configId, value });
          }),
      },
    };
  };

  it.effect("skips setConfigOption when the requested slug is omp-default", () =>
    Effect.gen(function* () {
      const { calls, runtime } = makeRuntime();
      yield* applyOmpAcpModelSelection({
        runtime,
        model: OMP_DEFAULT_MODEL_SLUG,
        selections: [{ id: "thinking", value: "medium" }],
        mapError: ({ cause }) => cause.message,
      });
      expect(calls).toEqual([]);
    }),
  );

  it.effect("calls setConfigOption only when the model differs from the current value", () =>
    Effect.gen(function* () {
      const { calls, runtime } = makeRuntime();
      yield* applyOmpAcpModelSelection({
        runtime,
        model: "google-antigravity/claude-sonnet-4-6",
        selections: undefined,
        mapError: ({ cause }) => cause.message,
      });
      expect(calls).toEqual([{ configId: "model", value: "google-antigravity/claude-sonnet-4-6" }]);
    }),
  );

  it.effect("does not set the model when it already matches the session", () =>
    Effect.gen(function* () {
      const { calls, runtime } = makeRuntime();
      yield* applyOmpAcpModelSelection({
        runtime,
        model: "google-antigravity/gemini-3.1-pro",
        selections: undefined,
        mapError: ({ cause }) => cause.message,
      });
      expect(calls).toEqual([]);
    }),
  );

  it.effect("sets thinking only when it differs from the current value", () =>
    Effect.gen(function* () {
      const { calls, runtime } = makeRuntime();
      yield* applyOmpAcpModelSelection({
        runtime,
        model: OMP_DEFAULT_MODEL_SLUG,
        selections: [{ id: "thinking", value: "high" }],
        mapError: ({ cause }) => cause.message,
      });
      expect(calls).toEqual([{ configId: "thinking", value: "high" }]);
    }),
  );

  it.effect("sets thinking again when the model switch reset it", () =>
    Effect.gen(function* () {
      const calls: Array<{ readonly configId: string; readonly value: string | boolean }> = [];
      let options = ompConfigOptions;
      yield* applyOmpAcpModelSelection({
        runtime: {
          getConfigOptions: Effect.sync(() => options),
          setConfigOption: (configId: string, value: string | boolean) =>
            Effect.sync(() => {
              calls.push({ configId, value });
              if (configId === "model") {
                options = options.map((option) =>
                  option.type === "select" && option.id === "thinking"
                    ? { ...option, currentValue: "low" }
                    : option,
                );
              }
            }),
        },
        model: "google-antigravity/claude-sonnet-4-6",
        selections: [{ id: "thinking", value: "medium" }],
        mapError: ({ cause }) => cause.message,
      });
      expect(calls).toEqual([
        { configId: "model", value: "google-antigravity/claude-sonnet-4-6" },
        { configId: "thinking", value: "medium" },
      ]);
    }),
  );
});

describe("isBareSlashCommand", () => {
  // Oh My Pi joins prompt text blocks with a blank line and reads everything
  // after the command name as the command's arguments, so a compaction turn
  // carrying a second block would compact toward that block's text.
  it.each(["/compact", "/clear", "  /compact  "])("treats %j as a bare command", (input) => {
    expect(isBareSlashCommand(input)).toBe(true);
  });

  it.each([
    "/compact focus on the refactor",
    "/compact\n\nYou are running inside a harness.",
    "please run /compact",
    "",
    "hello",
  ])("treats %j as ordinary prompt text", (input) => {
    expect(isBareSlashCommand(input)).toBe(false);
  });
});
