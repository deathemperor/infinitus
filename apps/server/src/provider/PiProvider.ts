<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
import {
  type CustomModelSetting,
  type ModelCapabilities,
  type PiSettings,
  PI_DEFAULT_MODEL,
=======
/**
 * PiProvider — snapshot/probe layer for the Pi coding agent.
 *
 * Health is probed with `pi --version`. Models, the user's default model, and
 * the user's commands (extension slash commands, prompt templates, skills)
 * are discovered through a short-lived ephemeral RPC session
 * (`pi --mode rpc --no-session`), so everything the user configured in
 * `~/.pi/agent` — custom providers, models.json entries, extensions, skills —
 * shows up in T3 without any hardcoded catalog.
 */
import {
  type CustomModelSetting,
  type PiSettings,
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
  type ServerProvider,
  type ServerProviderModel,
} from "@infinitus/contracts";
import { causeErrorTag } from "@infinitus/shared/observability";
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
import { createModelCapabilities } from "@infinitus/shared/model";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import { resolveSpawnCommand } from "@infinitus/shared/shell";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Result from "effect/Result";
import { HttpClient } from "effect/unstable/http";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

import {
  enrichProviderSnapshotWithVersionAdvisory,
  type ProviderMaintenanceCapabilities,
} from "../providerMaintenance.ts";
import {
  buildServerProvider,
  COMPACT_SLASH_COMMAND,
=======
import { resolveSpawnCommand } from "@infinitus/shared/shell";
import { compareSemverVersions } from "@infinitus/shared/semver";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Stream from "effect/Stream";
import * as Exit from "effect/Exit";
import * as Option from "effect/Option";
import * as Result from "effect/Result";
import { HttpClient } from "effect/http";
import { ChildProcess, ChildProcessSpawner } from "effect/process";

import {
  buildPiRpcLaunch,
  resolvePiLaunchArgs,
} from "../orchestration-v2/Adapters/piT3McpInjection.ts";
import {
  makePiRpcConnection,
  piRecordField as recordField,
  piRecordString as recordString,
} from "../orchestration-v2/Adapters/PiRpc.ts";
import {
  buildServerProvider,
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
  isCommandMissingCause,
  parseGenericCliVersion,
  providerModelsFromSettings,
  spawnAndCollect,
  type ServerProviderDraft,
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
} from "../providerSnapshot.ts";
import { parsePiModelsCliOutput } from "./piModels.logic.ts";
import { piHomeEnvironment } from "./piHomeEnvironment.ts";

/**
 * Pi runs every tool ungated — it ships no permission system at all (its own
 * README says so, and a live RPC run wrote a file with no approval event). The
 * driver refuses the supervised runtime modes rather than pretending to gate,
 * so the interaction-mode toggle has nothing to offer.
 */
const PI_PRESENTATION = {
  displayName: "Pi",
  supportsConversationRollback: false,
  badgeLabel: "Early Access",
  showInteractionModeToggle: false,
} as const;

const EMPTY_CAPABILITIES: ModelCapabilities = createModelCapabilities({ optionDescriptors: [] });

const VERSION_PROBE_TIMEOUT_MS = 4_000;
// `--list-models` reads the local catalogue but may refresh provider metadata.
const MODELS_PROBE_TIMEOUT_MS = 15_000;
// `--offline` keeps extension discovery (extensions register providers, and
// their models belong in the picker) but skips Pi's startup network work: the
// catalogue refresh and the npm install of a configured package that is not
// installed yet. Left on, the probe's timeout can kill that install mid-rename
// and leave npm's retire dir behind, after which every Pi launch, sessions
// included, fails with ENOTEMPTY.
const MODELS_PROBE_ARGS = ["--offline", "--list-models"];

const PI_BUILT_IN_MODELS: ReadonlyArray<ServerProviderModel> = [
  {
    slug: PI_DEFAULT_MODEL,
    name: "Pi default",
    isCustom: false,
    capabilities: EMPTY_CAPABILITIES,
  },
];

function piModelsFromSettings(
  customModels: ReadonlyArray<CustomModelSetting> | undefined,
  builtInModels: ReadonlyArray<ServerProviderModel> = PI_BUILT_IN_MODELS,
): ReadonlyArray<ServerProviderModel> {
  return providerModelsFromSettings(builtInModels, customModels ?? [], EMPTY_CAPABILITIES);
}

const runPiCliCommand = (
  piSettings: PiSettings,
  args: ReadonlyArray<string>,
  environment: NodeJS.ProcessEnv,
) =>
  Effect.gen(function* () {
    const command = piSettings.binaryPath || "pi";
    // A probe has to read the same config the session will: see
    // `piHomeEnvironment`, which also keeps an ambient Oh My Pi value out.
    const env = piHomeEnvironment(environment, piSettings.homePath);
    const spawnCommand = yield* resolveSpawnCommand(command, args, { env });
    return yield* spawnAndCollect(
      command,
      ChildProcess.make(spawnCommand.command, spawnCommand.args, {
        env,
=======
} from "./providerSnapshot.ts";
import {
  enrichProviderSnapshotWithVersionAdvisory,
  type ProviderMaintenanceCapabilities,
} from "./providerMaintenance.ts";
import {
  EMPTY_PI_MODEL_CAPABILITIES,
  thinkingCapabilitiesForPiModel,
} from "./piThinkingCapabilities.ts";
import {
  parsePiDiscoveredCommands,
  withPiBuiltinSlashCommands,
  type PiDiscoveredCommands,
} from "./PiCommands.ts";

const PI_PRESENTATION = {
  displayName: "Pi",
  showInteractionModeToggle: false,
  supportedRuntimeModes: ["approval-required", "auto-accept-edits", "full-access"],
  // The adapter reports context usage from Pi's streaming usage while a
  // turn runs, so clients can reserve the meter before the first settle.
  reportsContextWindow: true,
  requiresNewThreadForModelChange: false,
} as const;

const VERSION_PROBE_TIMEOUT_MS = 4_000;
const PI_RPC_DISCOVERY_TIMEOUT_MS = 15_000;
/**
 * get_entries arrived in 0.80.3 and agent_settled landed in source at 0.80.4.
 * Version 0.80.5 was the first published package containing both hooks. T3
 * needs them for rollback boundaries and reliable turn terminalization.
 */
export const MINIMUM_PI_VERSION = "0.80.5";

/** Deferring to the user's own settings.json default model. */
const PI_DEFAULT_MODEL: ServerProviderModel = {
  slug: "default",
  name: "Pi default",
  isCustom: false,
  capabilities: EMPTY_PI_MODEL_CAPABILITIES,
};

interface PiDiscovery extends PiDiscoveredCommands {
  readonly models: ReadonlyArray<ServerProviderModel>;
  readonly authenticated: boolean;
}

function piModelsFromSettings(
  customModels: ReadonlyArray<CustomModelSetting> | undefined,
  discovered: ReadonlyArray<ServerProviderModel> = [],
): ReadonlyArray<ServerProviderModel> {
  return providerModelsFromSettings(
    [PI_DEFAULT_MODEL, ...discovered],
    customModels ?? [],
    EMPTY_PI_MODEL_CAPABILITIES,
  );
}

function parseDiscoveredModels(
  data: unknown,
  defaultThinkingLevel: unknown,
): ReadonlyArray<ServerProviderModel> {
  const models = recordField(data, "models");
  if (!Array.isArray(models)) return [];
  const seen = new Set<string>();
  const parsed: Array<ServerProviderModel> = [];
  for (const model of models) {
    const provider = recordString(model, "provider");
    const id = recordString(model, "id");
    if (provider === undefined || id === undefined) continue;
    const slug = `${provider}/${id}`;
    if (seen.has(slug)) continue;
    seen.add(slug);
    parsed.push({
      slug,
      name: recordString(model, "name") ?? slug,
      subProvider: provider,
      isCustom: false,
      capabilities: thinkingCapabilitiesForPiModel(model, defaultThinkingLevel),
    });
  }
  return parsed;
}

const discoverPiViaRpc = (
  piSettings: PiSettings,
  environment: NodeJS.ProcessEnv,
  launchArgs: ReadonlyArray<string>,
  cwd?: string,
) =>
  Effect.gen(function* () {
    const launch = buildPiRpcLaunch({
      launchArgs,
      environment,
      mcpSession: undefined,
      extensionPath: undefined,
      ephemeral: true,
    });
    const connection = yield* makePiRpcConnection({
      command: piSettings.binaryPath || "pi",
      args: launch.args,
      cwd,
      env: launch.env,
    });
    yield* Stream.fromQueue(connection.events).pipe(
      Stream.runDrain,
      Effect.ignore,
      Effect.forkScoped,
    );
    const stateData = yield* connection.request({ type: "get_state" });
    const modelsData = yield* connection.request({ type: "get_available_models" });
    const commandsData = yield* connection
      .request({ type: "get_commands" })
      .pipe(Effect.orElseSucceed(() => undefined));
    const discoveredModels = parseDiscoveredModels(
      modelsData,
      recordString(stateData, "thinkingLevel"),
    );
    const { slashCommands, skills } = parsePiDiscoveredCommands(commandsData);
    return {
      models: discoveredModels,
      slashCommands: withPiBuiltinSlashCommands(slashCommands),
      skills,
      authenticated: discoveredModels.length > 0,
    } satisfies PiDiscovery;
  }).pipe(Effect.scoped);

const runPiVersionCommand = (piSettings: PiSettings, environment: NodeJS.ProcessEnv) =>
  Effect.gen(function* () {
    const command = piSettings.binaryPath || "pi";
    const spawnCommand = yield* resolveSpawnCommand(command, ["--version"], {
      env: environment,
    });
    return yield* spawnAndCollect(
      command,
      ChildProcess.make(spawnCommand.command, spawnCommand.args, {
        env: environment,
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
        shell: spawnCommand.shell,
      }),
    );
  });

export function buildInitialPiProviderSnapshot(
  piSettings: PiSettings,
): Effect.Effect<ServerProviderDraft> {
  return Effect.gen(function* () {
    const checkedAt = yield* Effect.map(DateTime.now, DateTime.formatIso);
    const models = piModelsFromSettings(piSettings.customModels);
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts

=======
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
    if (!piSettings.enabled) {
      return buildServerProvider({
        presentation: PI_PRESENTATION,
        enabled: false,
        checkedAt,
        models,
        probe: {
          installed: false,
          version: null,
          status: "warning",
          auth: { status: "unknown" },
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
          message: `Pi is disabled in ${PRODUCT_NAME} settings.`,
        },
      });
    }

=======
          message: "Pi is disabled in T3 Code settings.",
        },
      });
    }
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: true,
      checkedAt,
      models,
      probe: {
        installed: true,
        version: null,
        status: "warning",
        auth: { status: "unknown" },
        message: "Checking Pi CLI availability...",
      },
    });
  });
}

export const checkPiProviderStatus = Effect.fn("checkPiProviderStatus")(function* (
  piSettings: PiSettings,
  environment: NodeJS.ProcessEnv = process.env,
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
=======
  cwd?: string,
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
): Effect.fn.Return<ServerProviderDraft, never, ChildProcessSpawner.ChildProcessSpawner> {
  const checkedAt = DateTime.formatIso(yield* DateTime.now);
  const fallbackModels = piModelsFromSettings(piSettings.customModels);

  if (!piSettings.enabled) {
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: false,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: false,
        version: null,
        status: "warning",
        auth: { status: "unknown" },
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
        message: `Pi is disabled in ${PRODUCT_NAME} settings.`,
=======
        message: "Pi is disabled in T3 Code settings.",
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
      },
    });
  }

<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
  const versionResult = yield* runPiCliCommand(piSettings, ["--version"], environment).pipe(
=======
  const versionResult = yield* runPiVersionCommand(piSettings, environment).pipe(
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
    Effect.timeoutOption(VERSION_PROBE_TIMEOUT_MS),
    Effect.result,
  );

  if (Result.isFailure(versionResult)) {
    const error = versionResult.failure;
    yield* Effect.logWarning("Pi CLI health check failed.", { errorTag: error._tag });
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: !isCommandMissingCause(error),
        version: null,
        status: "error",
        auth: { status: "unknown" },
        message: isCommandMissingCause(error)
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
          ? "Pi CLI (`pi`) is not installed or not on PATH."
=======
          ? "Pi CLI (`pi`) is not installed or not on PATH. Install with `npm install -g @earendil-works/pi-coding-agent`."
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
          : "Failed to execute Pi CLI health check.",
      },
    });
  }

  if (Option.isNone(versionResult.success)) {
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version: null,
        status: "error",
        auth: { status: "unknown" },
        message: "Pi CLI is installed but timed out while running `pi --version`.",
      },
    });
  }

  const versionOutput = versionResult.success.value;
  const version = parseGenericCliVersion(`${versionOutput.stdout}\n${versionOutput.stderr}`);
  if (versionOutput.code !== 0) {
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
    yield* Effect.logWarning("Pi CLI version probe exited with a non-zero status.", {
      exitCode: versionOutput.code,
      stdoutLength: versionOutput.stdout.length,
      stderrLength: versionOutput.stderr.length,
    });
=======
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version,
        status: "error",
        auth: { status: "unknown" },
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
        message: "Pi CLI exited with an error while reporting its version.",
=======
        message: "Pi CLI is installed but failed to run.",
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
      },
    });
  }

<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
  const modelsResult = yield* runPiCliCommand(piSettings, MODELS_PROBE_ARGS, environment).pipe(
    Effect.timeoutOption(MODELS_PROBE_TIMEOUT_MS),
    Effect.result,
  );
  const modelsOutput =
    Result.isSuccess(modelsResult) &&
    Option.isSome(modelsResult.success) &&
    modelsResult.success.value.code === 0
      ? modelsResult.success.value
      : undefined;
  if (!modelsOutput) {
    yield* Effect.logWarning("Pi CLI model listing failed or timed out.", {
      errorTag: Result.isFailure(modelsResult)
        ? modelsResult.failure._tag
        : Option.isNone(modelsResult.success)
          ? "Timeout"
          : `ExitCode${modelsResult.success.value.code}`,
    });
  }

  const cliModels = modelsOutput
    ? parsePiModelsCliOutput(modelsOutput.stdout)
    : { authenticated: false, models: [] };
  const models = piModelsFromSettings(piSettings.customModels, [
    ...PI_BUILT_IN_MODELS,
    ...cliModels.models,
  ]);

  // A probe that could not run says nothing about auth. Pi's catalogue IS the
  // auth signal (there is no auth verb to ask), so an empty one means "not
  // signed in" only when the listing actually succeeded — otherwise the card
  // would tell a signed-in user to sign in because their network was slow.
  if (!modelsOutput) {
=======
  if (version === null) {
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
      models,
      slashCommands: [COMPACT_SLASH_COMMAND],
      probe: {
        installed: true,
        version,
        status: "warning",
        auth: { status: "unknown" },
        message: "Pi is installed but listing its models failed.",
=======
      models: fallbackModels,
      probe: {
        installed: true,
        version: null,
        status: "error",
        auth: { status: "unknown" },
        message: `T3 Code could not determine the Pi version. Pi ${MINIMUM_PI_VERSION} or newer is required.`,
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
      },
    });
  }

<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
=======
  if (compareSemverVersions(version, MINIMUM_PI_VERSION) < 0) {
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version,
        status: "error",
        auth: { status: "unknown" },
        message: `Pi ${version} is unsupported. Update to Pi ${MINIMUM_PI_VERSION} or newer.`,
      },
    });
  }

  const resolvedLaunchArgs = resolvePiLaunchArgs(piSettings.launchArgs);
  if (!resolvedLaunchArgs.ok) {
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version,
        status: "error",
        auth: { status: "unknown" },
        message: resolvedLaunchArgs.message,
      },
    });
  }

  const discoveryExit = yield* discoverPiViaRpc(
    piSettings,
    environment,
    resolvedLaunchArgs.args,
    cwd,
  ).pipe(Effect.timeoutOption(PI_RPC_DISCOVERY_TIMEOUT_MS), Effect.exit);
  if (Exit.isFailure(discoveryExit)) {
    yield* Effect.logWarning("Pi RPC discovery failed.", {
      errorTag: causeErrorTag(discoveryExit.cause),
    });
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version,
        status: "ready",
        auth: { status: "unknown" },
        message:
          "Pi is available, but T3 Code could not refresh its models and commands. The live session will retry startup.",
      },
    });
  }
  if (Option.isNone(discoveryExit.value)) {
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version,
        status: "ready",
        auth: { status: "unknown" },
        message:
          "Pi is available, but model and command discovery needs interactive input. The live session will handle it.",
      },
    });
  }

  const discovery = discoveryExit.value.value;
  const models = piModelsFromSettings(piSettings.customModels, discovery.models);
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
  return buildServerProvider({
    presentation: PI_PRESENTATION,
    enabled: piSettings.enabled,
    checkedAt,
    models,
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts
    // Pi enumerates no slash commands over its RPC surface, and its
    // interactive set is TUI-only, so only compaction is offered — the same
    // call Grok and Oh My Pi make.
    slashCommands: [COMPACT_SLASH_COMMAND],
    probe: {
      installed: true,
      version,
      status: cliModels.authenticated ? "ready" : "warning",
      // Pi lists a model only once its provider has usable auth, so a
      // non-empty catalogue IS the auth signal; there is no auth verb to ask.
      auth: cliModels.authenticated
        ? { status: "authenticated", type: "cached_token", label: "pi providers" }
        : { status: "unauthenticated" },
      ...(cliModels.authenticated ? {} : { message: "Run `pi` once to sign in to a provider." }),
=======
    slashCommands: discovery.slashCommands,
    skills: discovery.skills,
    probe: {
      installed: true,
      version,
      status: discovery.authenticated ? "ready" : "warning",
      auth: { status: discovery.authenticated ? "authenticated" : "unauthenticated", type: "pi" },
      ...(discovery.authenticated
        ? {}
        : {
            message:
              "Pi has no usable models. Run `pi` in a terminal and use /login, or configure an API key in ~/.pi/agent.",
          }),
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
    },
  });
});

export const enrichPiSnapshot = (input: {
  readonly snapshot: ServerProvider;
  readonly maintenanceCapabilities: ProviderMaintenanceCapabilities;
  readonly enableProviderUpdateChecks?: boolean;
  readonly publishSnapshot: (snapshot: ServerProvider) => Effect.Effect<void>;
  readonly httpClient: HttpClient.HttpClient;
}): Effect.Effect<void> => {
  const { snapshot, publishSnapshot } = input;
<<<<<<< HEAD:apps/server/src/provider/Layers/PiProvider.ts

=======
>>>>>>> upstream-sync-a4c9494b0-upstream-renamed:apps/server/src/provider/PiProvider.ts
  return enrichProviderSnapshotWithVersionAdvisory(snapshot, input.maintenanceCapabilities, {
    enableProviderUpdateChecks: input.enableProviderUpdateChecks,
  }).pipe(
    Effect.provideService(HttpClient.HttpClient, input.httpClient),
    Effect.flatMap((enrichedSnapshot) => publishSnapshot(enrichedSnapshot)),
    Effect.catchCause((cause) =>
      Effect.logWarning("Pi version advisory enrichment failed", {
        errorTag: causeErrorTag(cause),
      }),
    ),
    Effect.asVoid,
  );
};
