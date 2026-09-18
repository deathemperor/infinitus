import {
  type CustomModelSetting,
  type ModelCapabilities,
  type OmpSettings,
  type ServerProvider,
  type ServerProviderAuth,
  type ServerProviderModel,
} from "@infinitus/contracts";
import { causeErrorTag } from "@infinitus/shared/observability";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";
import { HttpClient } from "effect/unstable/http";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";
import { createModelCapabilities } from "@infinitus/shared/model";
import { resolveSpawnCommand } from "@infinitus/shared/shell";

import {
  AUTH_PROBE_TIMEOUT_MS,
  buildServerProvider,
  COMPACT_SLASH_COMMAND,
  isCommandMissingCause,
  parseGenericCliVersion,
  providerModelsFromSettings,
  spawnAndCollect,
  type ServerProviderDraft,
} from "../providerSnapshot.ts";
import {
  enrichProviderSnapshotWithVersionAdvisory,
  type ProviderMaintenanceCapabilities,
} from "../providerMaintenance.ts";
import { makeUnavailableUsageLimits } from "../providerUsageLimits.ts";
import { OMP_DEFAULT_MODEL_SLUG, resolveOmpAcpBaseModelId } from "../acp/OmpAcpSupport.ts";
import { ompCapacityToUsageLimits } from "./ompUsage.logic.ts";

const OMP_PRESENTATION = {
  displayName: "Oh My Pi",
  supportsConversationRollback: false,
  badgeLabel: "Early Access",
  showInteractionModeToggle: true,
} as const;
const EMPTY_CAPABILITIES: ModelCapabilities = createModelCapabilities({
  optionDescriptors: [],
});

const VERSION_PROBE_TIMEOUT_MS = 4_000;
// `omp usage` hits provider quota endpoints; larger than the local `--version` probe.
const USAGE_PROBE_TIMEOUT_MS = 15_000;
const OMP_UNAUTHENTICATED_MESSAGE = "Run `omp` once to sign in to a provider.";

/** omp's own `defaultThinkingLevel` default; used when `omp config get` cannot answer. */
export const OMP_FALLBACK_THINKING_LEVEL = "high";
// Levels omp's ACP thinking selector accepts: `off`, `auto`, and the ladder.
const OMP_THINKING_LEVELS: Record<string, true> = {
  off: true,
  auto: true,
  minimal: true,
  low: true,
  medium: true,
  high: true,
  xhigh: true,
  max: true,
};
// omp's ACP session lists these ahead of the model's own ladder, so the
// thread picker mirrors that: every value here is one `session/set_config_option`
// accepts, and the configured default can be `auto`.
const OMP_SESSION_THINKING_OPTIONS: ReadonlyArray<{ id: string; label: string }> = [
  { id: "off", label: "Off" },
  { id: "auto", label: "Auto" },
];

const OMP_BUILT_IN_MODELS: ReadonlyArray<ServerProviderModel> = [
  {
    slug: OMP_DEFAULT_MODEL_SLUG,
    name: "Session default",
    isCustom: false,
    capabilities: EMPTY_CAPABILITIES,
  },
];

export function buildInitialOmpProviderSnapshot(
  ompSettings: OmpSettings,
): Effect.Effect<ServerProviderDraft> {
  return Effect.gen(function* () {
    const checkedAt = yield* Effect.map(DateTime.now, DateTime.formatIso);
    const models = ompModelsFromSettings(ompSettings.customModels);

    if (!ompSettings.enabled) {
      return buildServerProvider({
        presentation: OMP_PRESENTATION,
        enabled: false,
        checkedAt,
        models,
        probe: {
          installed: false,
          version: null,
          status: "warning",
          auth: { status: "unknown" },
          message: `Oh My Pi is disabled in ${PRODUCT_NAME} settings.`,
        },
      });
    }

    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: true,
      checkedAt,
      models,
      probe: {
        installed: true,
        version: null,
        status: "warning",
        auth: { status: "unknown" },
        message: "Checking Oh My Pi CLI availability...",
      },
    });
  });
}

function ompModelsFromSettings(
  customModels: ReadonlyArray<CustomModelSetting> | undefined,
  builtInModels: ReadonlyArray<ServerProviderModel> = OMP_BUILT_IN_MODELS,
): ReadonlyArray<ServerProviderModel> {
  return providerModelsFromSettings(builtInModels, customModels ?? [], EMPTY_CAPABILITIES);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" ? value.trim() || undefined : undefined;
}

function thinkingOptionsFromModel(
  thinking: unknown,
  defaultThinkingLevel: string,
): ModelCapabilities {
  if (!Array.isArray(thinking)) {
    return EMPTY_CAPABILITIES;
  }
  const seen = new Set<string>(OMP_SESSION_THINKING_OPTIONS.map((option) => option.id));
  const options: Array<{ id: string; label: string }> = [...OMP_SESSION_THINKING_OPTIONS];
  for (const entry of thinking) {
    const value = nonEmptyString(entry);
    if (value === undefined || seen.has(value)) {
      continue;
    }
    seen.add(value);
    options.push({ id: value, label: value });
  }
  if (options.length === OMP_SESSION_THINKING_OPTIONS.length) {
    return EMPTY_CAPABILITIES;
  }
  // A new thread starts on omp's configured default, exactly what the ACP
  // session reports as its current level; without it the picker is blank.
  const currentValue = seen.has(defaultThinkingLevel) ? defaultThinkingLevel : undefined;
  return createModelCapabilities({
    optionDescriptors: [
      {
        id: "thinking",
        label: "Thinking",
        type: "select",
        options,
        ...(currentValue !== undefined ? { currentValue } : {}),
      },
    ],
  });
}

/**
 * Parses `omp config get defaultThinkingLevel`. Anything that is not a level
 * omp accepts (prose, an error, an empty answer) falls back to omp's own default.
 */
export function parseOmpDefaultThinkingLevel(output: string | undefined): string {
  const value = output?.trim().toLowerCase();
  return value !== undefined && OMP_THINKING_LEVELS[value] === true
    ? value
    : OMP_FALLBACK_THINKING_LEVEL;
}

export interface OmpModelsCliOutput {
  readonly authenticated: boolean;
  readonly models: ReadonlyArray<ServerProviderModel>;
}

/**
 * Parses `omp models --json`. A JSON object with a `models` array is a signed-in
 * catalog. Empty, missing, or unauthenticated prose ("No models available…")
 * is a warning, not an error — omp can be installed with zero credentials.
 */
export function parseOmpModelsCliOutput(
  output: string,
  defaultThinkingLevel: string = OMP_FALLBACK_THINKING_LEVEL,
): OmpModelsCliOutput {
  const trimmed = output.trim();
  if (trimmed.length === 0 || /no models available/i.test(trimmed)) {
    return { authenticated: false, models: [] };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed) as unknown;
  } catch {
    return { authenticated: false, models: [] };
  }

  const modelsRaw = isRecord(parsed) && Array.isArray(parsed.models) ? parsed.models : undefined;
  if (modelsRaw === undefined) {
    return { authenticated: false, models: [] };
  }

  const seen = new Set<string>([OMP_DEFAULT_MODEL_SLUG]);
  const models: ServerProviderModel[] = [];
  for (const entry of modelsRaw) {
    if (!isRecord(entry)) {
      continue;
    }
    const selector = nonEmptyString(entry.selector) ?? nonEmptyString(entry.id);
    if (selector === undefined) {
      continue;
    }
    const slug = resolveOmpAcpBaseModelId(selector);
    if (seen.has(slug)) {
      continue;
    }
    seen.add(slug);
    models.push({
      slug,
      name: nonEmptyString(entry.name) ?? slug,
      isCustom: false,
      capabilities: thinkingOptionsFromModel(entry.thinking, defaultThinkingLevel),
    });
  }

  return { authenticated: models.length > 0, models };
}

const decodeUnknownJson = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Unknown));

function parseOmpUsageJson(output: string): unknown | undefined {
  const trimmed = output.trim();
  if (trimmed.length === 0) return undefined;
  const decoded = decodeUnknownJson(trimmed);
  return Option.isSome(decoded) ? decoded.value : undefined;
}

const runOmpCliCommand = (
  ompSettings: OmpSettings,
  args: ReadonlyArray<string>,
  environment: NodeJS.ProcessEnv,
) =>
  Effect.gen(function* () {
    const command = ompSettings.binaryPath || "omp";
    const spawnCommand = yield* resolveSpawnCommand(command, args, { env: environment });
    return yield* spawnAndCollect(
      command,
      ChildProcess.make(spawnCommand.command, spawnCommand.args, {
        env: environment,
        shell: spawnCommand.shell,
      }),
    );
  });

export const checkOmpProviderStatus = Effect.fn("checkOmpProviderStatus")(function* (
  ompSettings: OmpSettings,
  environment: NodeJS.ProcessEnv = process.env,
): Effect.fn.Return<ServerProviderDraft, never, ChildProcessSpawner.ChildProcessSpawner> {
  const checkedAt = DateTime.formatIso(yield* DateTime.now);
  const fallbackModels = ompModelsFromSettings(ompSettings.customModels);

  if (!ompSettings.enabled) {
    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: false,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: false,
        version: null,
        status: "warning",
        auth: { status: "unknown" },
        message: `Oh My Pi is disabled in ${PRODUCT_NAME} settings.`,
      },
    });
  }

  const versionResult = yield* runOmpCliCommand(ompSettings, ["--version"], environment).pipe(
    Effect.timeoutOption(VERSION_PROBE_TIMEOUT_MS),
    Effect.result,
  );

  if (Result.isFailure(versionResult)) {
    const error = versionResult.failure;
    yield* Effect.logWarning("Oh My Pi CLI health check failed.", {
      errorTag: error._tag,
    });
    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: ompSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: !isCommandMissingCause(error),
        version: null,
        status: "error",
        auth: { status: "unknown" },
        message: isCommandMissingCause(error)
          ? "Oh My Pi CLI (`omp`) is not installed or not on PATH."
          : "Failed to execute Oh My Pi CLI health check.",
      },
    });
  }

  if (Option.isNone(versionResult.success)) {
    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: ompSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version: null,
        status: "error",
        auth: { status: "unknown" },
        message: "Oh My Pi CLI is installed but timed out while running `omp --version`.",
      },
    });
  }

  const versionOutput = versionResult.success.value;
  const version = parseGenericCliVersion(`${versionOutput.stdout}\n${versionOutput.stderr}`);
  if (versionOutput.code !== 0) {
    yield* Effect.logWarning("Oh My Pi CLI version probe exited with a non-zero status.", {
      exitCode: versionOutput.code,
      stdoutLength: versionOutput.stdout.length,
      stderrLength: versionOutput.stderr.length,
    });
    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: ompSettings.enabled,
      checkedAt,
      models: fallbackModels,
      probe: {
        installed: true,
        version,
        status: "error",
        auth: { status: "unknown" },
        message: "Oh My Pi CLI is installed but failed to run.",
      },
    });
  }

  const modelsResult = yield* runOmpCliCommand(ompSettings, ["models", "--json"], environment).pipe(
    Effect.timeoutOption(AUTH_PROBE_TIMEOUT_MS),
    Effect.result,
  );
  const modelsOutput =
    Result.isSuccess(modelsResult) &&
    Option.isSome(modelsResult.success) &&
    modelsResult.success.value.code === 0
      ? modelsResult.success.value
      : undefined;
  // The level a fresh ACP session opens on. Only worth asking once the catalog
  // answered; a failed probe falls back to omp's default rather than blanking
  // the thread picker.
  const thinkingLevelResult = modelsOutput
    ? yield* runOmpCliCommand(
        ompSettings,
        ["config", "get", "defaultThinkingLevel"],
        environment,
      ).pipe(Effect.timeoutOption(VERSION_PROBE_TIMEOUT_MS), Effect.result)
    : undefined;
  const thinkingLevelOutput =
    thinkingLevelResult !== undefined &&
    Result.isSuccess(thinkingLevelResult) &&
    Option.isSome(thinkingLevelResult.success) &&
    thinkingLevelResult.success.value.code === 0
      ? thinkingLevelResult.success.value.stdout
      : undefined;
  if (modelsOutput && thinkingLevelOutput === undefined) {
    yield* Effect.logWarning("Oh My Pi CLI default thinking level probe failed or timed out.", {
      errorTag:
        thinkingLevelResult === undefined || Result.isFailure(thinkingLevelResult)
          ? (thinkingLevelResult?.failure._tag ?? "Skipped")
          : Option.isNone(thinkingLevelResult.success)
            ? "Timeout"
            : `ExitCode${thinkingLevelResult.success.value.code}`,
    });
  }
  const cliModels: OmpModelsCliOutput = modelsOutput
    ? parseOmpModelsCliOutput(
        modelsOutput.stdout,
        parseOmpDefaultThinkingLevel(thinkingLevelOutput),
      )
    : { authenticated: false, models: [] };
  if (!modelsOutput) {
    yield* Effect.logWarning("Oh My Pi CLI model listing failed or timed out.", {
      errorTag: Result.isFailure(modelsResult)
        ? modelsResult.failure._tag
        : Option.isNone(modelsResult.success)
          ? "Timeout"
          : `ExitCode${modelsResult.success.value.code}`,
    });
  }

  const auth: ServerProviderAuth = cliModels.authenticated
    ? { status: "authenticated", type: "cached_token", label: "omp providers" }
    : { status: "unauthenticated" };

  const models =
    cliModels.models.length > 0
      ? ompModelsFromSettings(ompSettings.customModels, [
          ...OMP_BUILT_IN_MODELS,
          ...cliModels.models,
        ])
      : fallbackModels;

  // A probe that could not run says nothing about auth. `omp models --json`
  // answers only once a provider has credentials, so an empty catalogue means
  // "signed out" ONLY when the listing succeeded — otherwise the card would
  // tell a signed-in user to sign in because their network was slow. The usage
  // probe is skipped too: it would fail the same way.
  if (!modelsOutput) {
    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: ompSettings.enabled,
      checkedAt,
      models,
      slashCommands: [COMPACT_SLASH_COMMAND],
      probe: {
        installed: true,
        version,
        status: "warning",
        auth: { status: "unknown" },
        message: "Oh My Pi is installed but listing its models failed.",
      },
    });
  }

  if (auth.status === "unauthenticated") {
    return buildServerProvider({
      presentation: OMP_PRESENTATION,
      enabled: ompSettings.enabled,
      checkedAt,
      models,
      slashCommands: [COMPACT_SLASH_COMMAND],
      probe: {
        installed: true,
        version,
        status: "warning",
        auth,
        message: OMP_UNAUTHENTICATED_MESSAGE,
      },
    });
  }

  const usageResult = yield* runOmpCliCommand(
    ompSettings,
    ["usage", "--json", "--redact"],
    environment,
  ).pipe(Effect.timeoutOption(USAGE_PROBE_TIMEOUT_MS), Effect.result);

  const usageOutput =
    Result.isSuccess(usageResult) &&
    Option.isSome(usageResult.success) &&
    usageResult.success.value.code === 0
      ? usageResult.success.value
      : undefined;

  const parsedUsage = usageOutput !== undefined ? parseOmpUsageJson(usageOutput.stdout) : undefined;
  if (parsedUsage === undefined) {
    const errorTag = Result.isFailure(usageResult)
      ? usageResult.failure._tag
      : Option.isNone(usageResult.success)
        ? "Timeout"
        : usageResult.success.value.code !== 0
          ? `ExitCode${usageResult.success.value.code}`
          : "UnparseableJson";
    yield* Effect.logWarning("Oh My Pi CLI usage probe failed or timed out.", { errorTag });
  }

  const usageLimits =
    parsedUsage === undefined
      ? makeUnavailableUsageLimits({ checkedAt, reason: "probeFailed" })
      : ompCapacityToUsageLimits(parsedUsage, checkedAt);

  return buildServerProvider({
    presentation: OMP_PRESENTATION,
    enabled: ompSettings.enabled,
    checkedAt,
    models,
    slashCommands: [COMPACT_SLASH_COMMAND],
    probe: {
      installed: true,
      version,
      status: "ready",
      auth,
      usageLimits,
    },
  });
});

export const enrichOmpSnapshot = (input: {
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
      Effect.logWarning("Oh My Pi version advisory enrichment failed", {
        errorTag: causeErrorTag(cause),
      }),
    ),
    Effect.asVoid,
  );
};
