// @effect-diagnostics nodeBuiltinImport:off - the suite seeds and grows real
// transcript trees on disk, outside the service's Effect FileSystem.
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeSqlite from "node:sqlite";

import { assert, describe, it } from "@effect/vitest";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { HostProcessEnvironment, HostProcessPlatform } from "@infinitus/shared/hostProcess";
import { mergeUsage } from "@infinitus/shared/usageMerge";
import {
  EnvironmentId,
  ProviderDriverKind,
  ProviderInstanceId,
  UsageDay,
  type UsageSummaryInput,
} from "@infinitus/contracts";
import * as Duration from "effect/Duration";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Scheduler from "effect/Scheduler";
import * as Schema from "effect/Schema";
import * as TestClock from "effect/testing/TestClock";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";
import { ProcessRunner } from "../processRunner.ts";
import { HttpClient, HttpClientResponse } from "effect/unstable/http";

import * as ServerConfig from "../config.ts";
import * as ServerSettings from "../serverSettings.ts";
import { UsageAttribution } from "../infinitus/Services/UsageAttribution.ts";
import * as UsageService from "./UsageService.ts";

const encodeUnknownJson = Schema.encodeEffect(Schema.fromJsonString(Schema.Unknown));
const encodeUnknownJsonString = Schema.encodeSync(Schema.fromJsonString(Schema.Unknown));

function claudeLine(id: number, outputTokens: number, model = "claude-fable-5"): string {
  return `${JSON.stringify({
    type: "assistant",
    timestamp: "2026-08-01T10:00:00Z",
    requestId: `req_${id}`,
    sessionId: "session-1",
    message: {
      id: `msg_${id}`,
      model,
      usage: { input_tokens: 10, output_tokens: outputTokens },
    },
  })}\n`;
}

const WINDOW: UsageSummaryInput = {
  timeZone: "UTC",
  sinceDay: UsageDay.make("2026-07-31"),
  untilDay: UsageDay.make("2026-08-02"),
};

const setup = Effect.gen(function* () {
  // The service canonicalises the transcript roots (macOS keeps its temp
  // directory behind a symlink), so the fixture paths compare against theirs.
  const home = yield* Effect.promise(() =>
    NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "usage-service-test-")).then((dir) =>
      NodeFSP.realpath(dir),
    ),
  );
  yield* Effect.addFinalizer(() =>
    Effect.promise(() => NodeFSP.rm(home, { recursive: true, force: true })),
  );
  const transcriptDir = NodePath.join(home, "claude", "projects", "proj");
  yield* Effect.promise(() => NodeFSP.mkdir(transcriptDir, { recursive: true }));
  return {
    home,
    transcript: NodePath.join(transcriptDir, "session.jsonl"),
    settings: {
      providers: {
        claudeAgent: { homePath: NodePath.join(home, "claude") },
        codex: { homePath: NodePath.join(home, "codex") },
      },
    },
  };
});

const serviceLayers = (input: {
  readonly prefix: string;
  readonly home: string;
  readonly settings: Parameters<typeof ServerSettings.layerTest>[0];
  readonly onRatesFetch?: () => void;
  /** Defaults to an unparsable document so every scan retries the fetch. */
  readonly ratesDocument?: unknown;
  readonly environment?: NodeJS.ProcessEnv;
  readonly platform?: NodeJS.Platform;
}) =>
  ServerConfig.layerTest(process.cwd(), { prefix: input.prefix }).pipe(
    Layer.provideMerge(NodeServices.layer),
    Layer.provideMerge(Layer.succeed(HostProcessPlatform, input.platform ?? "linux")),
    Layer.provideMerge(ServerSettings.layerTest(input.settings)),
    Layer.provideMerge(
      Layer.succeed(
        HttpClient.HttpClient,
        HttpClient.make((request) =>
          Effect.sync(() => {
            input.onRatesFetch?.();
            // Unparsable rates: every scan retries the fetch, which makes the
            // fetch count a boundary-level observation of how many scans ran.
            return HttpClientResponse.fromWeb(request, Response.json(input.ratesDocument ?? {}));
          }),
        ),
      ),
    ),
    Layer.provideMerge(
      Layer.succeed(HostProcessEnvironment, {
        HOME: input.home,
        GROK_HOME: NodePath.join(input.home, "grok"),
        OPENCODE_DATA_DIR: NodePath.join(input.home, "opencode"),
        ANTIGRAVITY_DATA_DIR: NodePath.join(input.home, "antigravity"),
        XDG_CONFIG_HOME: NodePath.join(input.home, "config"),
        APPDATA: NodePath.join(input.home, "config"),
        ...input.environment,
      }),
    ),
  );

function totalOutputTokens(summary: { buckets: readonly { totals: { outputTokens: number } }[] }) {
  return summary.buckets.reduce((sum, bucket) => sum + bucket.totals.outputTokens, 0);
}

describe("UsageService", () => {
<<<<<<< HEAD
  it.live("attributes Claude records to the account the timeline names (#779)", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5, "example-model")));

      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const summary = yield* service.readSummary(WINDOW);

        assert.deepStrictEqual(summary.accounts?.lines, [
          {
            email: "one@example.invalid",
            label: "work",
            number: 1,
            totals: summary.buckets[0]!.totals,
            costUsd: 0,
            records: 1,
          },
        ]);
        assert.strictEqual(summary.accounts?.unattributed.records, 0);
        assert.strictEqual(summary.accounts?.notClaude.records, 0);
        assert.strictEqual(summary.accounts?.switchesInWindow, 1);
        assert.strictEqual(summary.accounts?.basis, "test history");
      }).pipe(
        Effect.provide(
          Layer.mergeAll(
            Layer.succeed(UsageAttribution, {
              resolve: Effect.succeed({
                accountAt: (timestampMs: number) =>
                  timestampMs >= Date.parse("2026-08-01T09:00:00Z") ? "one@example.invalid" : null,
                describe: () => ({ label: "work", number: 1 }),
                switchesAtMs: [
                  Date.parse("2026-07-01T09:00:00Z"),
                  Date.parse("2026-08-01T09:00:00Z"),
                  Date.parse("2026-09-15T09:00:00Z"),
                ],
                basis: "test history",
              }),
            }),
            serviceLayers({ prefix: "usage-service-attribution-test", home, settings }),
          ),
        ),
      );
    }).pipe(Effect.scoped),
  );

  it.live("carries no accounts without a timeline", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5, "example-model")));

      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const summary = yield* service.readSummary(WINDOW);
        assert.strictEqual(summary.accounts, undefined);
      }).pipe(
        Effect.provide(
          serviceLayers({ prefix: "usage-service-no-attribution-test", home, settings }),
        ),
      );
    }).pipe(Effect.scoped),
  );

  it.live("reads one session's transcript by name, deduped and priced (#834 backfill)", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      const dir = NodePath.dirname(transcript);
      yield* Effect.promise(() =>
        NodeFSP.writeFile(
          NodePath.join(dir, "abc-123.jsonl"),
          claudeLine(1, 5) + claudeLine(2, 7) + claudeLine(1, 5),
        ),
      );
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(3, 100)));

      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const found = yield* service.readSessionUsage({
          sessionIds: ["abc-123", "missing", "../abc-123", "session"],
        });
        assert.deepStrictEqual([...found.keys()], ["abc-123", "session"]);
        const one = found.get("abc-123");
        assert.deepStrictEqual(one?.totals, {
          uncachedInputTokens: 20,
          cachedInputTokens: 0,
          cacheCreationTokens: 0,
          outputTokens: 12,
          reasoningTokens: 0,
        });
        assert.closeTo(one?.costUsd ?? -1, 20 * 1e-5 + 12 * 5e-5, 1e-12);
        assert.deepStrictEqual(one?.models, ["claude-fable-5"]);
        assert.strictEqual(one?.lastAt, "2026-08-01T10:00:00.000Z");
        assert.strictEqual(found.get("session")?.totals.outputTokens, 100);
      }).pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-session-test",
            home,
            settings,
            ratesDocument: {
              "claude-fable-5": { input_cost_per_token: 1e-5, output_cost_per_token: 5e-5 },
=======
  it.live("does not read the macOS Cursor Keychain before account usage is enabled", () =>
    Effect.gen(function* () {
      const { settings, home } = yield* setup;
      const service = yield* UsageService.make.pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-cursor-keychain-disabled",
            home,
            settings,
            platform: "darwin",
            environment: {},
          }),
        ),
      );
      const summary = yield* service.readSummary(WINDOW);
      const cursor = summary.sources.find((source) => source.fingerprint.provider === "cursor");
      assert.strictEqual(cursor?.status, "missing");
      assert.strictEqual(cursor?.action, "enableCursorKeychain");
    }).pipe(Effect.scoped),
  );

  it.live("ignores stale Cursor file logins when the active credential store differs", () =>
    Effect.gen(function* () {
      const { settings, home } = yield* setup;
      for (const [index, testCase] of [
        {
          platform: "darwin" as const,
          environment: { AGENT_CLI_CREDENTIAL_STORE: "memory" },
          authPath: [".cursor", "auth.json"],
        },
        {
          platform: "linux" as const,
          environment: { AGENT_CLI_CREDENTIAL_STORE: "memory" },
          authPath: ["config", "cursor", "auth.json"],
        },
        {
          platform: "linux" as const,
          environment: { CURSOR_API_KEY: "different-account" },
          authPath: ["config", "cursor", "auth.json"],
        },
      ].entries()) {
        const authPath = NodePath.join(home, ...testCase.authPath);
        yield* Effect.promise(async () => {
          await NodeFSP.mkdir(NodePath.dirname(authPath), { recursive: true });
          await NodeFSP.writeFile(
            authPath,
            encodeUnknownJsonString({ accessToken: "stale-token" }),
          );
        });
        const service = yield* UsageService.make.pipe(
          Effect.provide(
            serviceLayers({
              prefix: `usage-service-cursor-store-${index}`,
              home,
              settings,
              platform: testCase.platform,
              environment: testCase.environment,
            }),
          ),
        );
        const summary = yield* service.readSummary(WINDOW);
        const cursor = summary.sources.find((source) => source.fingerprint.provider === "cursor");
        assert.strictEqual(cursor?.status, "missing");
        assert.include(cursor?.message ?? "", "Cursor CLI login");
        assert.isFalse(summary.buckets.some((bucket) => bucket.provider === "cursor"));
      }
    }).pipe(Effect.scoped),
  );

  it.live(
    "includes OpenCode history but does not substitute desktop usage for an unavailable Cursor account",
    () =>
      Effect.gen(function* () {
        const { settings, home } = yield* setup;
        const root = NodePath.join(home, "opencode");
        const message = yield* encodeUnknownJson({
          id: "msg_1",
          sessionID: "session-1",
          role: "assistant",
          modelID: "example-model",
          time: { created: Date.parse("2026-08-01T10:00:00Z") },
          tokens: { input: 10, output: 5, reasoning: 2, cache: { read: 20, write: 3 } },
        });
        const bubble = yield* encodeUnknownJson({
          type: 2,
          createdAt: "2026-08-01T10:00:00Z",
          modelInfo: { modelName: "example-model" },
          tokenCount: { inputTokens: 100, outputTokens: 20 },
        });
        yield* Effect.promise(async () => {
          const directory = NodePath.join(root, "storage", "message", "session-1");
          await NodeFSP.mkdir(directory, { recursive: true });
          await NodeFSP.writeFile(NodePath.join(directory, "msg_1.json"), message);
          const desktop = NodePath.join(home, "config", "Cursor", "User", "globalStorage");
          await NodeFSP.mkdir(desktop, { recursive: true });
          const db = new NodeSqlite.DatabaseSync(NodePath.join(desktop, "state.vscdb"));
          try {
            db.exec("CREATE TABLE cursorDiskKV (key TEXT, value TEXT)");
            db.prepare("INSERT INTO cursorDiskKV VALUES (?, ?)").run(
              "bubbleId:session:assistant",
              bubble,
            );
          } finally {
            db.close();
          }
        });
        const service = yield* UsageService.make.pipe(
          Effect.provide(serviceLayers({ prefix: "usage-service-opencode", home, settings })),
        );
        const summary = yield* service.readSummary(WINDOW);
        assert.strictEqual(summary.buckets[0]?.provider, "opencode");
        assert.isFalse(summary.buckets.some((bucket) => bucket.provider === "cursor"));
        assert.strictEqual(
          summary.sources.find((source) => source.fingerprint.provider === "cursor")?.status,
          "missing",
        );
        assert.strictEqual(
          summary.buckets[0]?.sourcePath,
          yield* Effect.promise(() => NodeFSP.realpath(root)),
        );
        assert.strictEqual(summary.buckets[0]?.totals.outputTokens, 7);
        assert.strictEqual(
          summary.sources.find((source) => source.fingerprint.provider === "opencode")
            ?.distinctSessions,
          1,
        );
        assert.include(
          summary.sources.find((source) => source.fingerprint.provider === "cursor")?.message ?? "",
          "Cursor account history needs a Cursor CLI login",
        );
      }).pipe(Effect.scoped),
  );

  it.live("counts aliased OpenCode and Antigravity directories once", () =>
    Effect.gen(function* () {
      const { settings, home } = yield* setup;
      const opencode = NodePath.join(home, "opencode-store");
      const opencodeAlias = NodePath.join(home, "opencode-alias");
      const conversations = NodePath.join(home, "antigravity-conversations");
      const antigravityA = NodePath.join(home, "antigravity-a");
      const antigravityB = NodePath.join(home, "antigravity-b");
      yield* Effect.promise(async () => {
        await NodeFSP.mkdir(opencode);
        await NodeFSP.symlink(opencode, opencodeAlias, "junction");
        await NodeFSP.mkdir(conversations);
        await NodeFSP.mkdir(antigravityA);
        await NodeFSP.mkdir(antigravityB);
        await NodeFSP.symlink(
          conversations,
          NodePath.join(antigravityA, "conversations"),
          "junction",
        );
        await NodeFSP.symlink(
          conversations,
          NodePath.join(antigravityB, "conversations"),
          "junction",
        );
      });
      const service = yield* UsageService.make.pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-aliased-roots-test",
            home,
            settings,
            environment: {
              OPENCODE_DATA_DIR: `${opencode},${opencodeAlias}`,
              ANTIGRAVITY_DATA_DIR: `${antigravityA},${antigravityB}`,
>>>>>>> upstream-sync-295d7cba0-upstream-renamed
            },
          }),
        ),
      );
<<<<<<< HEAD
=======
      const summary = yield* service.readSummary(WINDOW);
      const sourcesFor = (provider: "opencode" | "antigravity") =>
        summary.sources.filter((source) => source.fingerprint.provider === provider);
      assert.strictEqual(sourcesFor("opencode").length, 1);
      assert.strictEqual(sourcesFor("antigravity").length, 1);
      assert.strictEqual(
        sourcesFor("opencode")[0]?.fingerprint.resolvedHomePath,
        yield* Effect.promise(() => NodeFSP.realpath(opencode)),
      );
      assert.strictEqual(
        sourcesFor("antigravity")[0]?.fingerprint.resolvedHomePath,
        yield* Effect.promise(() => NodeFSP.realpath(conversations)),
      );
>>>>>>> upstream-sync-295d7cba0-upstream-renamed
    }).pipe(Effect.scoped),
  );

  it.live("reads configured and disabled accounts once across shared and aliased homes", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      const codexHome = NodePath.join(home, "codex-account");
      const alias = NodePath.join(home, "codex-alias");
      const claudeHome = NodePath.join(home, "claude-account");
      const grokHome = NodePath.join(home, "grok-account");
      yield* Effect.promise(async () => {
        await NodeFSP.writeFile(transcript, claudeLine(1, 5));
        await NodeFSP.mkdir(NodePath.join(claudeHome, "projects"), { recursive: true });
        await NodeFSP.writeFile(
          NodePath.join(claudeHome, "projects", "session.jsonl"),
          claudeLine(2, 7),
        );
        await NodeFSP.mkdir(NodePath.join(codexHome, "sessions"), { recursive: true });
        await NodeFSP.symlink(codexHome, alias, "junction");
        await NodeFSP.writeFile(
          NodePath.join(codexHome, "sessions", "rollout.jsonl"),
          [
            { type: "session_meta", payload: { id: "codex-account-session" } },
            { type: "turn_context", payload: { model: "gpt-5.6-sol" } },
            // A-B-A at one timestamp must preserve both equal A events.
            ...[11, 12, 11].map((outputTokens) => ({
              type: "event_msg",
              timestamp: "2026-08-01T10:00:00Z",
              payload: {
                type: "token_count",
                info: { last_token_usage: { input_tokens: 10, output_tokens: outputTokens } },
              },
            })),
          ]
            .map((line) => encodeUnknownJsonString(line))
            .join("\n") + "\n",
        );
        await NodeFSP.mkdir(NodePath.join(grokHome, "sessions", "session"), { recursive: true });
        await NodeFSP.writeFile(
          NodePath.join(grokHome, "sessions", "session", "updates.jsonl"),
          encodeUnknownJsonString({
            timestamp: Date.parse("2026-08-01T10:00:00Z") / 1000,
            method: "_x.ai/session/update",
            params: {
              sessionId: "grok-account-session",
              update: {
                sessionUpdate: "turn_completed",
                prompt_id: "prompt-1",
                usage: { inputTokens: 10, outputTokens: 13 },
              },
            },
          }) + "\n",
        );
      });
      const service = yield* UsageService.make.pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-accounts-test",
            home,
            settings: {
              ...settings,
              providerInstances: {
                [ProviderInstanceId.make("claude-work")]: {
                  driver: ProviderDriverKind.make("claudeAgent"),
                  enabled: false,
                  environment: [{ name: "CLAUDE_CONFIG_DIR", value: claudeHome, sensitive: false }],
                },
                [ProviderInstanceId.make("codex-work")]: {
                  driver: ProviderDriverKind.make("codex"),
                  environment: [{ name: "CODEX_HOME", value: codexHome, sensitive: false }],
                },
                [ProviderInstanceId.make("codex-alias")]: {
                  driver: ProviderDriverKind.make("codex"),
                  config: { homePath: alias },
                },
                [ProviderInstanceId.make("codex-shadow")]: {
                  driver: ProviderDriverKind.make("codex"),
                  config: { homePath: codexHome, shadowHomePath: NodePath.join(home, "shadow") },
                  environment: [
                    { name: "CODEX_HOME", value: NodePath.join(home, "ignored"), sensitive: false },
                  ],
                },
                [ProviderInstanceId.make("grok-work")]: {
                  driver: ProviderDriverKind.make("grok"),
                  environment: [{ name: "GROK_HOME", value: grokHome, sensitive: false }],
                },
              },
            },
          }),
        ),
      );
      const summary = yield* service.readSummary(WINDOW);
      assert.strictEqual(totalOutputTokens(summary), 59);
      yield* Effect.promise(() =>
        NodeFSP.rename(
          NodePath.join(codexHome, "sessions", "rollout.jsonl"),
          NodePath.join(codexHome, "sessions", "moved.jsonl"),
        ),
      );
      const moved = yield* service.readSummary(WINDOW);
      assert.deepStrictEqual(moved.buckets, summary.buckets);
      yield* Effect.promise(() =>
        NodeFSP.rm(NodePath.join(codexHome, "sessions"), { recursive: true }),
      );
      const removed = yield* service.readSummary(WINDOW);
      assert.deepStrictEqual(removed.buckets, summary.buckets);

      const sources = summary.sources.filter((source) => source.status === "ok");
      assert.strictEqual(sources.length, 4);
      assert.strictEqual(
        sources.reduce((sum, source) => sum + source.scannedFiles, 0),
        4,
      );
      assert.strictEqual(
        sources.filter((source) => source.fingerprint.provider === "codex").length,
        1,
      );
    }).pipe(Effect.scoped),
  );

  it.live(
    "uses explicit account settings before environment and legacy homes, then refreshes them",
    () =>
      Effect.gen(function* () {
        const { transcript, settings, home } = yield* setup;
        const configured = NodePath.join(home, "configured");
        const environmentHome = NodePath.join(home, "environment");
        yield* Effect.promise(async () => {
          await NodeFSP.writeFile(transcript, claudeLine(1, 100));
          for (const [index, root] of [configured, environmentHome].entries()) {
            await NodeFSP.mkdir(NodePath.join(root, "projects"), { recursive: true });
            await NodeFSP.writeFile(
              NodePath.join(root, "projects", "session.jsonl"),
              claudeLine(index + 2, index + 7),
            );
          }
          await NodeFSP.mkdir(NodePath.join(configured, ".claude", "projects"), {
            recursive: true,
          });
          await NodeFSP.writeFile(
            NodePath.join(configured, ".claude", "projects", "wrong.jsonl"),
            claudeLine(4, 1000),
          );
        });
        yield* Effect.gen(function* () {
          const settingsService = yield* ServerSettings.ServerSettingsService;
          const service = yield* UsageService.make;
          const first = yield* service.readSummary(WINDOW);
          assert.strictEqual(totalOutputTokens(first), 7);
          const configuredProjects = yield* Effect.promise(() =>
            NodeFSP.realpath(NodePath.join(configured, "projects")),
          );
          assert.include(
            first.sources.map((source) => source.fingerprint.resolvedHomePath),
            configuredProjects,
          );
          yield* settingsService.updateSettings({
            providerInstances: {
              [ProviderInstanceId.make("claudeAgent")]: {
                driver: ProviderDriverKind.make("claudeAgent"),
                config: { homePath: "" },
                environment: [
                  { name: "CLAUDE_CONFIG_DIR", value: environmentHome, sensitive: false },
                ],
              },
            },
          });
          const second = yield* service.readSummary(WINDOW);
          assert.strictEqual(totalOutputTokens(second), 8);
          const environmentProjects = yield* Effect.promise(() =>
            NodeFSP.realpath(NodePath.join(environmentHome, "projects")),
          );
          assert.include(
            second.sources.map((source) => source.fingerprint.resolvedHomePath),
            environmentProjects,
          );
        }).pipe(
          Effect.provide(
            serviceLayers({
              prefix: "usage-service-home-refresh-test",
              home,
              environment: { CLAUDE_CONFIG_DIR: NodePath.join(home, "host-ignored") },
              settings: {
                ...settings,
                providerInstances: {
                  [ProviderInstanceId.make("claudeAgent")]: {
                    driver: ProviderDriverKind.make("claudeAgent"),
                    config: { homePath: configured },
                    environment: [
                      { name: "CLAUDE_CONFIG_DIR", value: environmentHome, sensitive: false },
                    ],
                  },
                },
              },
            }),
          ),
        );
      }).pipe(Effect.scoped),
  );

  it.live(
    "uses inherited home variables when explicit default accounts have no home settings",
    () =>
      Effect.gen(function* () {
        const { transcript, settings, home } = yield* setup;
        yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5)));
        const service = yield* UsageService.make.pipe(
          Effect.provide(
            serviceLayers({
              prefix: "usage-service-inherited-homes-test",
              home,
              environment: {
                CODEX_HOME: NodePath.join(home, "inherited-codex"),
                CLAUDE_CONFIG_DIR: NodePath.join(home, "claude"),
              },
              settings: {
                ...settings,
                providerInstances: {
                  [ProviderInstanceId.make("codex")]: {
                    driver: ProviderDriverKind.make("codex"),
                    config: {},
                  },
                  [ProviderInstanceId.make("claudeAgent")]: {
                    driver: ProviderDriverKind.make("claudeAgent"),
                    config: {},
                  },
                },
              },
            }),
          ),
        );
        const summary = yield* service.readSummary(WINDOW);
        assert.strictEqual(totalOutputTokens(summary), 5);
        assert.strictEqual(
          summary.sources.find((source) => source.fingerprint.provider === "codex")?.fingerprint
            .resolvedHomePath,
          NodePath.join(home, "inherited-codex", "sessions"),
        );
        assert.strictEqual(
          summary.sources.find((source) => source.fingerprint.provider === "grok")?.fingerprint
            .resolvedHomePath,
          NodePath.join(home, "grok", "sessions"),
        );
      }).pipe(Effect.scoped),
  );

  it.live("reprices unchanged transcripts when custom prices are added, edited, or removed", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5, "example-model")));

      yield* Effect.gen(function* () {
        const settingsService = yield* ServerSettings.ServerSettingsService;
        const service = yield* UsageService.make;

        const original = yield* service.readSummary(WINDOW);
        assert.strictEqual(original.buckets[0]?.costUsd, 0);
        assert.strictEqual(original.buckets[0]?.unpricedRecords, 1);

        yield* settingsService.updateSettings({
          usagePriceOverrides: {
            "example-model": { inputCostPerMillionTokens: 2, outputCostPerMillionTokens: 8 },
          },
        });
        const overridden = yield* service.readSummary(WINDOW);
        assert.closeTo(overridden.buckets[0]?.costUsd ?? -1, 0.00006, 1e-12);
        assert.strictEqual(overridden.buckets[0]?.costSource, "modelPriced");
        assert.strictEqual(overridden.buckets[0]?.unpricedRecords, 0);
        assert.deepStrictEqual(overridden.buckets[0]?.totals, original.buckets[0]?.totals);

        yield* settingsService.updateSettings({
          usagePriceOverrides: {
            "example-model": { inputCostPerMillionTokens: 4, outputCostPerMillionTokens: 16 },
          },
        });
        const edited = yield* service.readSummary(WINDOW);
        assert.closeTo(edited.buckets[0]?.costUsd ?? -1, 0.00012, 1e-12);

        yield* settingsService.updateSettings({ usagePriceOverrides: { "example-model": null } });
        const restored = yield* service.readSummary(WINDOW);
        assert.deepStrictEqual(restored.buckets, original.buckets);
      }).pipe(
        Effect.provide(
          serviceLayers({ prefix: "usage-service-price-overrides-test", home, settings }),
        ),
      );
    }).pipe(Effect.scoped),
  );

  it.live("counts appended usage on a rescan of a grown transcript", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5)));

      const service = yield* UsageService.make.pipe(
        Effect.provide(serviceLayers({ prefix: "usage-service-grow-test", home, settings })),
      );

      const first = yield* service.readSummary(WINDOW);
      assert.strictEqual(totalOutputTokens(first), 5);

      yield* Effect.promise(() => NodeFSP.appendFile(transcript, claudeLine(2, 7)));
      const second = yield* service.readSummary(WINDOW);
      assert.strictEqual(totalOutputTokens(second), 12);
    }).pipe(Effect.scoped),
  );

  it.live("preserves saved tokens, costs and sessions after transcript cleanup and restart", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      const alias = NodePath.join(home, "claude-alias");
      yield* Effect.promise(() =>
        NodeFSP.symlink(NodePath.join(home, "claude"), alias, "junction"),
      );
      const content = claudeLine(1, 5);
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, content));
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const first = yield* service.readSummary(WINDOW);
        assert.strictEqual(totalOutputTokens(first), 5);
        assert.isAbove(first.buckets[0]?.costUsd ?? 0, 0);

        yield* Effect.promise(() => NodeFSP.rm(transcript));
        const deleted = yield* service.readSummary(WINDOW);
        assert.deepStrictEqual(deleted.buckets, first.buckets);
        assert.deepStrictEqual(deleted.sources, first.sources);

        const restarted = yield* UsageService.make;
        const restored = yield* restarted.readSummary(WINDOW);
        assert.deepStrictEqual(restored.buckets, first.buckets);
        assert.deepStrictEqual(restored.sources, first.sources);

        // A moved transcript must not count the saved usage twice.
        yield* Effect.promise(() => NodeFSP.writeFile(transcript + ".jsonl", content));
        const moved = yield* restarted.readSummary(WINDOW);
        assert.deepStrictEqual(moved.buckets, first.buckets);
        assert.strictEqual(moved.sources[0]?.distinctSessions, 1);

        const replacementProjects = NodePath.join(home, "replacement-projects");
        yield* Effect.promise(() => NodeFSP.mkdir(replacementProjects));
        yield* Effect.promise(() =>
          NodeFSP.rm(NodePath.join(home, "claude", "projects"), { recursive: true }),
        );
        const afterRootCleanup = yield* UsageService.make;
        const missingRoot = yield* afterRootCleanup.readSummary(WINDOW);
        assert.deepStrictEqual(missingRoot.buckets, first.buckets);
        assert.strictEqual(missingRoot.sources[0]?.distinctSessions, 1);
        assert.strictEqual(missingRoot.sources[0]?.status, "ok");
        assert.deepStrictEqual(missingRoot.sources[0]?.fingerprint, first.sources[0]?.fingerprint);
        yield* Effect.promise(async () => {
          const projects = NodePath.join(home, "claude", "projects");
          await NodeFSP.rename(replacementProjects, projects);
          await NodeFSP.writeFile(NodePath.join(projects, "new.jsonl"), claudeLine(2, 7));
        });
        const recreated = yield* afterRootCleanup.readSummary(WINDOW);
        assert.strictEqual(totalOutputTokens(recreated), 12);
        assert.deepStrictEqual(recreated.sources[0]?.fingerprint, first.sources[0]?.fingerprint);

        const merged = mergeUsage(
          [
            {
              environmentId: EnvironmentId.make("cleanup-test"),
              label: "test",
              summary: recreated,
            },
            {
              environmentId: EnvironmentId.make("other-environment"),
              label: "before cleanup",
              summary: first,
            },
          ],
          missingRoot.contractVersion,
        );
        assert.strictEqual(merged.outputTokens, 12);
        assert.strictEqual(merged.sessions, 1);
        assert.strictEqual(merged.costUsd, recreated.buckets[0]?.costUsd);

        const outsideWindow = yield* restarted.readSummary({
          ...WINDOW,
          sinceDay: UsageDay.make("2026-08-02"),
        });
        assert.deepStrictEqual(outsideWindow.buckets, []);
        assert.strictEqual(outsideWindow.sources[0]?.distinctSessions, 0);
      }).pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-cleanup-test",
            home,
            settings: { providers: { ...settings.providers, claudeAgent: { homePath: alias } } },
            ratesDocument: {
              "claude-fable-5": { input_cost_per_token: 1e-5, output_cost_per_token: 5e-5 },
            },
          }),
        ),
      );
    }).pipe(Effect.scoped),
  );

  it.live("does not share an in-flight scan after custom prices change", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5, "example-model")));
      const transcriptDir = yield* Effect.promise(() =>
        NodeFSP.realpath(NodePath.join(home, "claude", "projects")),
      );

      yield* Effect.gen(function* () {
        const settingsService = yield* ServerSettings.ServerSettingsService;
        const fileSystem = yield* FileSystem.FileSystem;
        const firstScanStarted = yield* Deferred.make<void>();
        const secondScanStarted = yield* Deferred.make<void>();
        const releaseRates = yield* Deferred.make<void>();
        let homeProbes = 0;
        const service = yield* UsageService.make.pipe(
          Effect.provideService(FileSystem.FileSystem, {
            ...fileSystem,
            exists: (path) =>
              fileSystem.exists(path).pipe(
                Effect.tap(() => {
                  if (path !== transcriptDir) return Effect.void;
                  homeProbes += 1;
                  return Deferred.succeed(
                    homeProbes === 1 ? firstScanStarted : secondScanStarted,
                    undefined,
                  );
                }),
              ),
          }),
          Effect.provideService(
            HttpClient.HttpClient,
            HttpClient.make((request) =>
              Deferred.await(releaseRates).pipe(
                Effect.as(HttpClientResponse.fromWeb(request, Response.json({}))),
              ),
            ),
          ),
        );

        const first = yield* service.readSummary(WINDOW).pipe(Effect.forkChild);
        yield* Deferred.await(firstScanStarted);
        yield* settingsService.updateSettings({
          usagePriceOverrides: {
            "example-model": { inputCostPerMillionTokens: 2, outputCostPerMillionTokens: 8 },
          },
        });
        const second = yield* service.readSummary(WINDOW).pipe(Effect.forkChild);
        yield* Deferred.await(secondScanStarted);
        yield* Deferred.succeed(releaseRates, undefined);

        const original = yield* Fiber.join(first);
        const updated = yield* Fiber.join(second);
        assert.strictEqual(original.buckets[0]?.costUsd, 0);
        assert.closeTo(updated.buckets[0]?.costUsd ?? -1, 0.00006, 1e-12);
      }).pipe(
        Effect.provide(serviceLayers({ prefix: "usage-service-price-race-test", home, settings })),
      );
    }).pipe(Effect.scoped),
  );

  it.live("shares one scan between concurrent identical requests", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5)));

      let ratesFetches = 0;
      const service = yield* UsageService.make.pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-flight-test",
            home,
            settings,
            onRatesFetch: () => {
              ratesFetches += 1;
            },
          }),
        ),
      );

      const [first, second] = yield* Effect.all(
        [service.readSummary(WINDOW), service.readSummary(WINDOW)],
        { concurrency: 2 },
      );
      assert.deepStrictEqual(first, second);
      assert.strictEqual(ratesFetches, 1);

      // A later request is fresh work again, not a stale cached answer.
      yield* service.readSummary(WINDOW);
      assert.strictEqual(ratesFetches, 2);
    }).pipe(Effect.scoped),
  );

  it.live("refetches a rate table inside its TTL only when the client asks", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5)));

      let ratesFetches = 0;
      const service = yield* UsageService.make.pipe(
        Effect.provide(
          serviceLayers({
            prefix: "usage-service-rates-refresh-test",
            home,
            settings,
            ratesDocument: {
              "claude-fable-5": { input_cost_per_token: 1e-5, output_cost_per_token: 5e-5 },
            },
            onRatesFetch: () => {
              ratesFetches += 1;
            },
          }),
        ),
      );

      const first = yield* service.readSummary(WINDOW);
      assert.strictEqual(ratesFetches, 1);
      assert.strictEqual(first.pricing.status, "fresh");

      // Inside the daily TTL a plain rescan keeps the cached table.
      yield* TestClock.adjust(Duration.minutes(2));
      yield* service.readSummary(WINDOW);
      assert.strictEqual(ratesFetches, 1);

      // An explicit refresh fetches again so a newly listed model gets priced.
      // A burst of refreshes shares that one fetch.
      const [refreshed] = yield* Effect.all([service.refreshRates, service.refreshRates], {
        concurrency: 2,
      });
      assert.strictEqual(ratesFetches, 2);
      assert.strictEqual(refreshed.status, "fresh");
      assert.strictEqual(refreshed.knownModels, 1);
    }).pipe(Effect.scoped, Effect.provide(TestClock.layer())),
  );

  it.live("does not orphan an in-flight scan when its first caller is interrupted", () =>
    Effect.gen(function* () {
      const { settings, home } = yield* setup;
      const service = yield* UsageService.make.pipe(
        Effect.provide(
          serviceLayers({ prefix: "usage-service-interruption-test", home, settings }),
        ),
      );

      let orphanedAt: number | undefined;
      for (let interruptAt = 1; interruptAt <= 31; interruptAt += 1) {
        const tasks: Array<() => void> = [];
        const dispatcher: Scheduler.SchedulerDispatcher = {
          scheduleTask: (task) => tasks.push(task),
          flush: () => {
            let task: (() => void) | undefined;
            while ((task = tasks.shift()) !== undefined) task();
          },
        };

        let requestFiber: Fiber.Fiber<unknown, unknown> | undefined;
        let requestChecks = 0;
        const scheduler: Scheduler.Scheduler = {
          executionMode: "async",
          makeDispatcher: () => dispatcher,
          shouldYield: (fiber) => {
            if (fiber !== requestFiber) return false;
            requestChecks += 1;
            if (requestChecks !== interruptAt) return false;
            fiber.interruptUnsafe();
            return true;
          },
        };

        // Each candidate needs a distinct key because the broken case leaves
        // its entry in the service's private in-flight map. The invalid window
        // keeps the real scan synchronous once its detached fiber starts.
        const input: UsageSummaryInput = {
          ...WINDOW,
          sinceDay: UsageDay.make("2026-09-01"),
          untilDay: UsageDay.make(`2026-08-${String(interruptAt).padStart(2, "0")}`),
        };
        const first = yield* service
          .readSummary(input)
          .pipe(
            Effect.exit,
            Effect.provideService(Scheduler.Scheduler, scheduler),
            Effect.forkChild,
          );
        requestFiber = first;
        yield* Effect.yieldNow;
        dispatcher.flush();

        const second = yield* service.readSummary(input).pipe(
          Effect.match({
            onFailure: (error) => error.reason,
            onSuccess: () => "success" as const,
          }),
          Effect.provideService(Scheduler.Scheduler, scheduler),
          Effect.forkChild,
        );
        yield* Effect.yieldNow;
        dispatcher.flush();
        const secondExit = second.pollUnsafe();
        if (secondExit === undefined) {
          second.interruptUnsafe();
          orphanedAt = interruptAt;
          break;
        }
        if (Exit.isFailure(secondExit)) {
          assert.fail("the matching request fiber was interrupted");
        }
        assert.strictEqual(secondExit.value, "invalidWindow");
      }

      assert.isUndefined(
        orphanedAt,
        `interruption left the next matching request pending at scheduler check ${orphanedAt}`,
      );
    }).pipe(Effect.scoped),
  );
});

describe("portable Stats service", () => {
  for (const provider of ["claude", "codex"] as const) {
    it.live(
      `counts an unterminated ${provider} activity event once across cache, restart, and append`,
      () =>
        Effect.gen(function* () {
          const { transcript, settings, home } = yield* setup;
          const codexDir = NodePath.join(home, "codex", "sessions");
          yield* Effect.promise(() => NodeFSP.mkdir(codexDir, { recursive: true }));
          const file =
            provider === "claude" ? transcript : NodePath.join(codexDir, "rollout.jsonl");
          const event = (type: string, payload: unknown) =>
            encodeUnknownJsonString({
              type,
              payload,
              timestamp: "2026-08-01T10:00:00Z",
            }) + "\n";
          const prefix =
            provider === "claude"
              ? claudeLine(1, 5)
              : event("session_meta", { id: "tail-session" }) +
                event("turn_context", { model: "gpt-test" }) +
                event("event_msg", {
                  type: "token_count",
                  info: { last_token_usage: { input_tokens: 10, output_tokens: 5 } },
                });
          const user = (second: number) =>
            encodeUnknownJsonString(
              provider === "claude"
                ? {
                    type: "user",
                    sessionId: "session-1",
                    timestamp: `2026-08-01T10:00:0${second}Z`,
                    message: { content: "hello" },
                  }
                : {
                    type: "event_msg",
                    timestamp: `2026-08-01T10:00:0${second}Z`,
                    payload: { type: "user_message", message: "hello" },
                  },
            );
          yield* Effect.promise(() => NodeFSP.writeFile(file, prefix + user(1)));
          yield* Effect.gen(function* () {
            const service = yield* UsageService.make;
            const request = {
              period: "week" as const,
              today: UsageDay.make("2026-08-01"),
              timeZone: "UTC",
            };
            yield* service.readSummary(WINDOW);
            const first = yield* service.readStats(request);
            assert.strictEqual(first.sessions[0]?.days[0]?.day.humanMessages, 1);
            assert.strictEqual(first.sessions[0]?.days[0]?.day.outputTokens, 5);
            assert.deepStrictEqual((yield* service.readStats(request)).sessions, first.sessions);
            const restarted = yield* UsageService.make;
            assert.deepStrictEqual((yield* restarted.readStats(request)).sessions, first.sessions);
            yield* Effect.promise(() => NodeFSP.appendFile(file, "\n" + user(2) + "\n"));
            // Usage can be the first reader of the grown file with cached activity.
            yield* restarted.readSummary(WINDOW);
            const grown = yield* restarted.readStats(request);
            assert.strictEqual(grown.sessions[0]?.days[0]?.day.humanMessages, 2);
            assert.strictEqual(grown.sessions[0]?.days[0]?.day.outputTokens, 5);
          }).pipe(
            Effect.provide(serviceLayers({ prefix: `stats-tail-${provider}`, home, settings })),
          );
        }).pipe(Effect.scoped),
    );
  }

  it.live("a future reporting date cannot prune retained usage after transcript cleanup", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() => NodeFSP.writeFile(transcript, claudeLine(1, 5)));
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        assert.strictEqual(totalOutputTokens(yield* service.readSummary(WINDOW)), 5);
        yield* Effect.promise(() => NodeFSP.unlink(transcript));
        yield* service.readStats({
          period: "week",
          today: UsageDay.make("2035-01-01"),
          timeZone: "UTC",
        });
        // Restart so neither the summary memo nor the in-memory cache can hide data loss.
        const restarted = yield* UsageService.make;
        assert.strictEqual(totalOutputTokens(yield* restarted.readSummary(WINDOW)), 5);
      }).pipe(Effect.provide(serviceLayers({ prefix: "stats-retention", home, settings })));
    }).pipe(Effect.scoped),
  );

  it.live("Usage reads finish while a Stats repository command is blocked", () =>
    Effect.gen(function* () {
      const { transcript, settings, home } = yield* setup;
      yield* Effect.promise(() =>
        NodeFSP.writeFile(
          transcript,
          encodeUnknownJsonString({
            type: "user",
            sessionId: "session-1",
            cwd: home,
            timestamp: "2026-08-01T09:59:00Z",
            message: { content: "hello" },
          }) +
            "\n" +
            claudeLine(1, 5),
        ),
      );
      const repositoryStarted = yield* Deferred.make<void>();
      const releaseRepository = yield* Deferred.make<void>();
      const runner = ProcessRunner.of({
        run: () =>
          Effect.gen(function* () {
            yield* Deferred.succeed(repositoryStarted, undefined);
            yield* Deferred.await(releaseRepository);
            return {
              stdout: "",
              stderr: "",
              code: ChildProcessSpawner.ExitCode(1),
              timedOut: false,
              stdoutTruncated: false,
              stderrTruncated: false,
              stdoutInvalidUtf8: false,
              stderrInvalidUtf8: false,
            };
          }),
      });
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const stats = yield* service
          .readStats({
            period: "week",
            today: UsageDay.make("2026-08-01"),
            timeZone: "UTC",
          })
          .pipe(Effect.forkChild);
        yield* Deferred.await(repositoryStarted);
        yield* Effect.gen(function* () {
          assert.strictEqual(totalOutputTokens(yield* service.readSummary(WINDOW)), 5);
          const sessions = yield* service.readSessionUsage({ sessionIds: ["session"] });
          assert.strictEqual(sessions.get("session")?.totals.outputTokens, 5);
        }).pipe(Effect.ensuring(Deferred.succeed(releaseRepository, undefined)));
        yield* Fiber.join(stats);
      }).pipe(
        Effect.provideService(ProcessRunner, runner),
        Effect.provide(serviceLayers({ prefix: "stats-concurrency", home, settings })),
      );
    }).pipe(Effect.scoped),
  );

  it.live("backfills a Usage cache, resumes activity, and reprices historical Codex usage", () =>
    Effect.gen(function* () {
      const { home, settings } = yield* setup;
      const dir = NodePath.join(home, "codex", "sessions");
      yield* Effect.promise(() => NodeFSP.mkdir(dir, { recursive: true }));
      const file = NodePath.join(dir, "rollout.jsonl");
      const line = (type: string, payload: unknown, second = 0) =>
        JSON.stringify({
          type,
          payload,
          timestamp: `2026-08-01T10:00:${String(second).padStart(2, "0")}Z`,
        }) + "\n";
      const first =
        line("session_meta", { id: "stats-codex" }) +
        line("turn_context", { model: "gpt-test", effort: "high" }) +
        line("event_msg", { type: "user_message", message: "hello" }) +
        line(
          "event_msg",
          {
            type: "token_count",
            info: {
              last_token_usage: {
                input_tokens: 1000,
                cached_input_tokens: 600,
                output_tokens: 200,
                reasoning_output_tokens: 100,
              },
            },
          },
          1,
        ) +
        line("event_msg", { type: "task_complete" }, 2);
      yield* Effect.promise(() => NodeFSP.writeFile(file, first));
      yield* Effect.gen(function* () {
        const service = yield* UsageService.make;
        const request = {
          period: "month" as const,
          today: UsageDay.make("2026-08-01"),
          timeZone: "UTC",
        };
        yield* service.readSummary(WINDOW);
        const initial = yield* service.readStats(request);
        assert.strictEqual(initial.sessions.length, 1);
        assert.strictEqual(initial.sessions[0]!.days[0]!.day.unpricedRecords, 1);
        const settingsService = yield* ServerSettings.ServerSettingsService;
        yield* settingsService.updateSettings({
          usagePriceOverrides: {
            "gpt-test": {
              inputCostPerMillionTokens: 2,
              outputCostPerMillionTokens: 10,
              cacheReadCostPerMillionTokens: 0.5,
            },
          },
        });
        const priced = yield* service.readStats(request);
        assert.closeTo(priced.sessions[0]!.days[0]!.day.usd!, 0.0031, 1e-9);
        assert.strictEqual(priced.sessions[0]!.days[0]!.day.humanMessages, 1);
        yield* Effect.promise(() =>
          NodeFSP.appendFile(
            file,
            line("event_msg", { type: "user_message", message: "again" }, 3) +
              line(
                "response_item",
                {
                  type: "function_call",
                  name: "exec_command",
                  call_id: "c1",
                  arguments: '{"cmd":"pwd"}',
                },
                4,
              ),
          ),
        );
        const grown = yield* service.readStats(request);
        assert.strictEqual(grown.sessions[0]!.days[0]!.day.humanMessages, 2);
        assert.strictEqual(grown.sessions[0]!.days[0]!.day.toolCalls?.exec_command, 1);
        assert.strictEqual(grown.sessions[0]!.days[0]!.day.outputTokens, 200);
        const restarted = yield* UsageService.make;
        assert.deepStrictEqual((yield* restarted.readStats(request)).sessions, grown.sessions);
        yield* Effect.promise(() => NodeFSP.copyFile(file, NodePath.join(dir, "moved-copy.jsonl")));
        const copied = yield* service.readStats(request);
        assert.strictEqual(copied.sessions.length, 1);
        assert.strictEqual(copied.sessions[0]!.days[0]!.day.outputTokens, 200);
        yield* Effect.promise(() => NodeFSP.writeFile(file, first));
        yield* Effect.promise(() => NodeFSP.unlink(NodePath.join(dir, "moved-copy.jsonl")));
        // Retained copies are still deduplicated after cleanup.
        assert.strictEqual((yield* service.readStats(request)).sessions.length, 1);
      }).pipe(Effect.provide(serviceLayers({ prefix: "portable-stats", home, settings })));
    }).pipe(Effect.scoped),
  );
});
