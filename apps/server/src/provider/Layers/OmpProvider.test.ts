// @effect-diagnostics nodeBuiltinImport:off preferSchemaOverJson:off
import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";
import { OmpSettings } from "@infinitus/contracts";

import {
  buildInitialOmpProviderSnapshot,
  checkOmpProviderStatus,
  parseOmpDefaultThinkingLevel,
  parseOmpModelsCliOutput,
} from "./OmpProvider.ts";
import { writeFakeCli } from "../../testUtils/fakeCli.ts";

const decodeOmpSettings = Schema.decodeSync(OmpSettings);

const AUTHENTICATED_MODELS_JSON = JSON.stringify({
  models: [
    {
      provider: "google-antigravity",
      id: "gemini-3.1-pro",
      selector: "google-antigravity/gemini-3.1-pro",
      name: "Gemini 3.1 Pro",
      thinking: ["minimal", "low", "medium", "high"],
    },
    {
      provider: "google-antigravity",
      id: "claude-sonnet-4-6",
      selector: "google-antigravity/claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      thinking: ["low", "medium", "high"],
    },
  ],
});

const AUTHENTICATED_USAGE_JSON = JSON.stringify({
  generatedAt: 1_726_400_000_000,
  reports: [],
  accountsWithoutUsage: [],
  disabledCredentials: [],
  capacity: {
    "google-antigravity": [
      {
        window: "5h",
        durationMs: 18_000_000,
        accounts: 1,
        usedAccounts: 0,
        remainingAccounts: 1,
      },
      {
        window: "7d",
        durationMs: 604_800_000,
        accounts: 1,
        usedAccounts: 0.0355,
        remainingAccounts: 0.9645,
      },
    ],
    zai: [
      {
        window: "5h",
        durationMs: 18_000_000,
        accounts: 2,
        usedAccounts: 1,
        remainingAccounts: 1,
      },
    ],
  },
});

describe("parseOmpModelsCliOutput", () => {
  it("reads model slugs, names, and thinking descriptors from JSON", () => {
    const parsed = parseOmpModelsCliOutput(AUTHENTICATED_MODELS_JSON);
    expect(parsed.authenticated).toBe(true);
    expect(parsed.models.map((model) => model.slug)).toEqual([
      "google-antigravity/gemini-3.1-pro",
      "google-antigravity/claude-sonnet-4-6",
    ]);
    expect(parsed.models[0]?.name).toBe("Gemini 3.1 Pro");
    // Off and Auto lead, as in omp's own ACP selector; omp's default level is
    // preselected so a fresh thread's picker is not blank.
    expect(parsed.models[0]?.capabilities?.optionDescriptors).toEqual([
      {
        id: "thinking",
        label: "Thinking",
        type: "select",
        currentValue: "high",
        options: [
          { id: "off", label: "Off" },
          { id: "auto", label: "Auto" },
          { id: "minimal", label: "minimal" },
          { id: "low", label: "low" },
          { id: "medium", label: "medium" },
          { id: "high", label: "high" },
        ],
      },
    ]);
  });

  it("preselects the configured default level, including auto", () => {
    const [gemini] = parseOmpModelsCliOutput(AUTHENTICATED_MODELS_JSON, "auto").models;
    expect(gemini?.capabilities?.optionDescriptors[0]).toMatchObject({ currentValue: "auto" });
  });

  it("leaves the level unselected when the model lacks the configured default", () => {
    const [, sonnet] = parseOmpModelsCliOutput(AUTHENTICATED_MODELS_JSON, "minimal").models;
    expect(sonnet?.capabilities?.optionDescriptors[0]).not.toHaveProperty("currentValue");
  });

  it("parses `omp config get defaultThinkingLevel`, falling back to omp's default", () => {
    expect(parseOmpDefaultThinkingLevel("medium\n")).toBe("medium");
    expect(parseOmpDefaultThinkingLevel("Auto")).toBe("auto");
    expect(parseOmpDefaultThinkingLevel("")).toBe("high");
    expect(parseOmpDefaultThinkingLevel(undefined)).toBe("high");
    expect(parseOmpDefaultThinkingLevel("Unknown setting: defaultThinkingLevel")).toBe("high");
  });

  it("treats unauthenticated prose as not authenticated", () => {
    const parsed = parseOmpModelsCliOutput("No models available. Set API keys to continue.\n");
    expect(parsed.authenticated).toBe(false);
    expect(parsed.models).toEqual([]);
  });

  it("treats empty stdout as not authenticated", () => {
    expect(parseOmpModelsCliOutput("").authenticated).toBe(false);
  });
});

describe("buildInitialOmpProviderSnapshot", () => {
  it.effect("returns a disabled snapshot when settings.enabled is false", () =>
    Effect.gen(function* () {
      const snapshot = yield* buildInitialOmpProviderSnapshot(
        decodeOmpSettings({ enabled: false }),
      );
      expect(snapshot.status).toBe("disabled");
      expect(snapshot.message).toContain("disabled");
    }),
  );

  it.effect("returns a disabled snapshot by default — Oh My Pi is opt-in", () =>
    Effect.gen(function* () {
      const snapshot = yield* buildInitialOmpProviderSnapshot(decodeOmpSettings({}));
      expect(snapshot.status).toBe("disabled");
    }),
  );
});

it.layer(NodeServices.layer)("checkOmpProviderStatus", (it) => {
  it.effect("returns a disabled snapshot without spawning when disabled", () =>
    Effect.gen(function* () {
      const snapshot = yield* checkOmpProviderStatus(decodeOmpSettings({ enabled: false }));
      expect(snapshot.status).toBe("disabled");
      expect(snapshot.installed).toBe(false);
    }),
  );

  const writeFakeOmpCli = (input: {
    readonly modelsOutput: string;
    readonly modelsExitCode?: number;
    readonly usageOutput?: string;
    readonly usageExitCode?: number;
    readonly thinkingLevelOutput?: string;
    readonly thinkingLevelExitCode?: number;
  }) =>
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const dir = yield* fs.makeTempDirectoryScoped({ prefix: "t3code-omp-probe-" });
      // Every invocation appends its argv, so a test can prove which
      // subcommands the probe ran — above all that it never ran `acp`.
      const argvLog = `${dir}/argv.log`;
      const path = writeFakeCli({
        directory: dir,
        name: "omp",
        source: [
          'import { appendFileSync as appendArgv } from "node:fs";',
          `appendArgv(${JSON.stringify(argvLog)}, process.argv.slice(2).join(" ") + "\\n");`,
          'if (process.argv[2] === "--version") {',
          '  process.stdout.write("omp/18.1.21\\n");',
          "  process.exit(0);",
          "}",
          'if (process.argv[2] === "models") {',
          // @effect-diagnostics-next-line preferSchemaOverJson:off
          `  process.stdout.write(${JSON.stringify(input.modelsOutput)});`,
          `  process.exit(${input.modelsExitCode ?? 0});`,
          "}",
          'if (process.argv[2] === "config" && process.argv[3] === "get") {',
          `  process.stdout.write(${JSON.stringify(input.thinkingLevelOutput ?? "high\n")});`,
          `  process.exit(${input.thinkingLevelExitCode ?? 0});`,
          "}",
          'if (process.argv[2] === "usage") {',
          // @effect-diagnostics-next-line preferSchemaOverJson:off
          `  process.stdout.write(${JSON.stringify(input.usageOutput ?? AUTHENTICATED_USAGE_JSON)});`,
          `  process.exit(${input.usageExitCode ?? 0});`,
          "}",
          "process.exit(1);",
          "",
        ].join("\n"),
      });
      const readArgv = Effect.gen(function* () {
        const exists = yield* fs.exists(argvLog);
        if (!exists) return [] as ReadonlyArray<string>;
        const contents = yield* fs.readFileString(argvLog);
        return contents.split("\n").filter((line) => line.length > 0);
      });
      return { path, readArgv };
    });

  it.effect("reports ready with models --json slugs when signed in", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("ready");
      expect(snapshot.version).toBe("18.1.21");
      expect(snapshot.auth).toEqual({
        status: "authenticated",
        type: "cached_token",
        label: "omp providers",
      });
      expect(snapshot.models.map((model) => model.slug)).toEqual([
        "omp-default",
        "google-antigravity/gemini-3.1-pro",
        "google-antigravity/claude-sonnet-4-6",
      ]);
      expect(snapshot.models[0]?.name).toBe("Session default");
      expect(snapshot.supportsTextGeneration).toBeUndefined();
    }),
  );

  it.effect("preselects the level omp config reports for every listed model", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
            thinkingLevelOutput: "medium\n",
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      const levels = snapshot.models
        .filter((model) => model.slug !== "omp-default")
        .map((model) => model.capabilities?.optionDescriptors[0])
        .map((descriptor) => (descriptor?.type === "select" ? descriptor.currentValue : null));
      expect(levels).toEqual(["medium", "medium"]);
    }),
  );

  it.effect("falls back to omp's default level when the config probe fails", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
            thinkingLevelOutput: "",
            thinkingLevelExitCode: 2,
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("ready");
      const descriptor = snapshot.models[1]?.capabilities?.optionDescriptors[0];
      expect(descriptor?.type === "select" ? descriptor.currentValue : null).toBe("high");
    }),
  );

  it.effect("does not claim a signed-in user is signed out when the model probe fails", () =>
    Effect.gen(function* () {
      const { snapshot, argv } = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath, readArgv } = yield* writeFakeOmpCli({
            modelsOutput: "",
            modelsExitCode: 3,
          });
          const result = yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
          return { snapshot: result, argv: yield* readArgv };
        }),
      );

      // `omp models --json` answers only once a provider has credentials, so
      // an empty catalogue reads as "signed out" — but only when the listing
      // actually ran. Telling a signed-in user to sign in because their
      // network was slow sends them round a pointless loop.
      expect(snapshot.installed).toBe(true);
      expect(snapshot.version).toBe("18.1.21");
      expect(snapshot.auth).toEqual({ status: "unknown" });
      expect(snapshot.message).not.toMatch(/sign in/i);
      // The usage probe would fail the same way, so it is not attempted.
      expect(argv.some((line) => line.startsWith("usage"))).toBe(false);
    }),
  );

  it.effect("surfaces usage limits from omp usage --json --redact", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
            usageOutput: AUTHENTICATED_USAGE_JSON,
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("ready");
      expect(snapshot.usageLimits?.unavailable).toBeUndefined();
      expect(snapshot.usageLimits?.windows.map((window) => window.id).sort()).toEqual([
        "google-antigravity:5h",
        "google-antigravity:7d",
        "zai:5h",
      ]);
      expect(
        snapshot.usageLimits?.windows.find((window) => window.id === "google-antigravity:5h"),
      ).toEqual({
        id: "google-antigravity:5h",
        kind: "session",
        label: "google-antigravity · Session",
        usedPercent: 0,
        windowDurationMins: 300,
      });
    }),
  );

  it.effect("reports probeFailed when omp usage fails", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
            usageExitCode: 1,
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("ready");
      expect(snapshot.usageLimits).toEqual({
        checkedAt: snapshot.checkedAt,
        windows: [],
        unavailable: { reason: "probeFailed" },
      });
    }),
  );

  it.effect("reports probeFailed when omp usage returns unparseable JSON", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
            usageOutput: "not-json",
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("ready");
      expect(snapshot.usageLimits?.unavailable).toEqual({ reason: "probeFailed" });
    }),
  );

  it.effect("reports unauthenticated from empty models --json as a warning", () =>
    Effect.gen(function* () {
      const snapshot = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath } = yield* writeFakeOmpCli({
            modelsOutput: "No models available. Set API keys to continue.\n",
          });
          return yield* checkOmpProviderStatus(
            decodeOmpSettings({ enabled: true, binaryPath: ompPath }),
          );
        }),
      );

      expect(snapshot.status).toBe("warning");
      expect(snapshot.auth.status).toBe("unauthenticated");
      expect(snapshot.message).toContain("Run `omp` once to sign in");
      expect(snapshot.models.map((model) => model.slug)).toEqual(["omp-default"]);
    }),
  );

  it.effect("probes with --version, models, config, and usage, never starting ACP", () =>
    Effect.gen(function* () {
      const invocations = yield* Effect.scoped(
        Effect.gen(function* () {
          const { path: ompPath, readArgv } = yield* writeFakeOmpCli({
            modelsOutput: AUTHENTICATED_MODELS_JSON,
            usageOutput: AUTHENTICATED_USAGE_JSON,
          });
          yield* checkOmpProviderStatus(decodeOmpSettings({ enabled: true, binaryPath: ompPath }));
          return yield* readArgv;
        }),
      );

      expect(invocations.length).toBeGreaterThan(0);
      // A health probe that spawned `omp acp` would hold an agent session
      // open for every refresh.
      expect(invocations.some((argv) => argv.split(" ").includes("acp"))).toBe(false);
      expect(invocations).toContain("--version");
      expect(invocations.some((argv) => argv.startsWith("models"))).toBe(true);
      expect(invocations).toContain("config get defaultThinkingLevel");
      expect(invocations).toContain("usage --json --redact");
      expect(
        invocations.every(
          (argv) =>
            argv === "--version" ||
            argv.startsWith("models") ||
            argv === "config get defaultThinkingLevel" ||
            argv.startsWith("usage"),
        ),
      ).toBe(true);
    }),
  );
});
