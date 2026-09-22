import {
  type CustomModelSetting,
  type ModelCapabilities,
  type PiSettings,
  PI_DEFAULT_MODEL,
  type ServerProvider,
  type ServerProviderModel,
} from "@infinitus/contracts";
import { causeErrorTag } from "@infinitus/shared/observability";
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
  isCommandMissingCause,
  parseGenericCliVersion,
  providerModelsFromSettings,
  spawnAndCollect,
  type ServerProviderDraft,
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
          message: `Pi is disabled in ${PRODUCT_NAME} settings.`,
        },
      });
    }

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
        message: `Pi is disabled in ${PRODUCT_NAME} settings.`,
      },
    });
  }

  const versionResult = yield* runPiCliCommand(piSettings, ["--version"], environment).pipe(
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
          ? "Pi CLI (`pi`) is not installed or not on PATH."
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
    yield* Effect.logWarning("Pi CLI version probe exited with a non-zero status.", {
      exitCode: versionOutput.code,
      stdoutLength: versionOutput.stdout.length,
      stderrLength: versionOutput.stderr.length,
    });
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
        message: "Pi CLI exited with an error while reporting its version.",
      },
    });
  }

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
    return buildServerProvider({
      presentation: PI_PRESENTATION,
      enabled: piSettings.enabled,
      checkedAt,
      models,
      slashCommands: [COMPACT_SLASH_COMMAND],
      probe: {
        installed: true,
        version,
        status: "warning",
        auth: { status: "unknown" },
        message: "Pi is installed but listing its models failed.",
      },
    });
  }

  return buildServerProvider({
    presentation: PI_PRESENTATION,
    enabled: piSettings.enabled,
    checkedAt,
    models,
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
