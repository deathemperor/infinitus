import {
  type OmpSettings,
  ProviderDriverKind,
  type ProviderOptionSelection,
  type RuntimeMode,
} from "@infinitus/contracts";
import { getProviderOptionStringSelectionValue, normalizeModelSlug } from "@infinitus/shared/model";
import * as Crypto from "effect/Crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Scope from "effect/Scope";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";
import type * as EffectAcpErrors from "effect-acp/errors";
import type * as EffectAcpSchema from "effect-acp/schema";

import * as AcpSessionRuntime from "./AcpSessionRuntime.ts";

const OMP_DRIVER_KIND = ProviderDriverKind.make("omp");

type OmpAcpRuntimeOmpSettings = Pick<OmpSettings, "binaryPath">;

function ompAcpSpawnArgs(runtimeMode?: RuntimeMode): ReadonlyArray<string> {
  switch (runtimeMode) {
    case "full-access":
      return ["--no-title", "--yolo", "acp"];
    default:
      return ["--no-title", "acp"];
  }
}

export interface OmpAcpRuntimeInput extends Omit<
  AcpSessionRuntime.AcpSessionRuntimeOptions,
  "authMethodId" | "clientCapabilities" | "spawn"
> {
  readonly childProcessSpawner: ChildProcessSpawner.ChildProcessSpawner["Service"];
  readonly ompSettings: OmpAcpRuntimeOmpSettings | null | undefined;
  readonly environment?: NodeJS.ProcessEnv;
  readonly runtimeMode?: RuntimeMode;
}

export interface OmpAcpModelSelectionErrorContext {
  readonly cause: EffectAcpErrors.AcpError;
  readonly step: "set-config-option";
  readonly configId?: string;
}

export function buildOmpAcpSpawnInput(
  ompSettings: OmpAcpRuntimeOmpSettings | null | undefined,
  cwd: string,
  environment?: NodeJS.ProcessEnv,
  runtimeMode?: RuntimeMode,
): AcpSessionRuntime.AcpSpawnInput {
  return {
    command: ompSettings?.binaryPath || "omp",
    args: [...ompAcpSpawnArgs(runtimeMode)],
    cwd,
    ...(environment ? { env: environment } : {}),
  };
}

export const makeOmpAcpRuntime = (
  input: OmpAcpRuntimeInput,
): Effect.Effect<
  AcpSessionRuntime.AcpSessionRuntime["Service"],
  EffectAcpErrors.AcpError,
  Crypto.Crypto | Scope.Scope
> =>
  Effect.gen(function* () {
    const acpContext = yield* Layer.build(
      AcpSessionRuntime.layer({
        ...input,
        spawn: buildOmpAcpSpawnInput(
          input.ompSettings,
          input.cwd,
          input.environment,
          input.runtimeMode,
        ),
        authMethodId: "agent",
        // Oh My Pi advertises sessionCapabilities.resume. Its session/load
        // replays the whole transcript before answering and stamps no
        // `_meta.isReplay`, so the runtime only drops those updates because
        // they land while the session is still Starting. session/resume skips
        // the replay outright.
        resumeMethod: "resume",
      }).pipe(
        Layer.provide(
          Layer.succeed(ChildProcessSpawner.ChildProcessSpawner, input.childProcessSpawner),
        ),
      ),
    );
    return yield* Effect.service(AcpSessionRuntime.AcpSessionRuntime).pipe(
      Effect.provide(acpContext),
    );
  });

/**
 * T3's built-in Oh My Pi slug. It is not a model id the ACP session accepts,
 * so selecting it means "use whatever model the omp session currently runs on".
 */
export const OMP_DEFAULT_MODEL_SLUG = "omp-default";

export function resolveOmpAcpBaseModelId(model: string | null | undefined): string {
  const trimmed = model?.trim();
  const base = trimmed && trimmed.length > 0 ? trimmed : OMP_DEFAULT_MODEL_SLUG;
  return normalizeModelSlug(base, OMP_DRIVER_KIND) ?? OMP_DEFAULT_MODEL_SLUG;
}

interface OmpAcpModelSelectionRuntime {
  readonly getConfigOptions: AcpSessionRuntime.AcpSessionRuntime["Service"]["getConfigOptions"];
  readonly setConfigOption: (
    configId: string,
    value: string | boolean,
  ) => Effect.Effect<unknown, EffectAcpErrors.AcpError>;
}

function currentSelectValue(
  option: EffectAcpSchema.SessionConfigOption | undefined,
): string | undefined {
  if (!option || typeof option.currentValue !== "string") {
    return undefined;
  }
  const trimmed = option.currentValue.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export function applyOmpAcpModelSelection<E>(input: {
  readonly runtime: OmpAcpModelSelectionRuntime;
  readonly model: string | null | undefined;
  readonly selections: ReadonlyArray<ProviderOptionSelection> | null | undefined;
  readonly mapError: (context: OmpAcpModelSelectionErrorContext) => E;
}): Effect.Effect<void, E> {
  return Effect.gen(function* () {
    const configOptions = yield* input.runtime.getConfigOptions;
    const modelOption = configOptions.find((option) => option.category === "model");
    const requestedModelId = resolveOmpAcpBaseModelId(input.model);
    if (
      requestedModelId !== OMP_DEFAULT_MODEL_SLUG &&
      modelOption &&
      requestedModelId !== currentSelectValue(modelOption)
    ) {
      const configId = modelOption.id.trim() || "model";
      yield* input.runtime.setConfigOption(configId, requestedModelId).pipe(
        Effect.mapError((cause) =>
          input.mapError({
            cause,
            step: "set-config-option",
            configId,
          }),
        ),
      );
    }

    const requestedThinking = getProviderOptionStringSelectionValue(input.selections, "thinking");
    // Read again: a model switch answers with fresh options, and the new
    // model may not keep the thinking level the old one had.
    const currentOptions = yield* input.runtime.getConfigOptions;
    const thinkingOption =
      currentOptions.find((option) => option.id.trim() === "thinking") ??
      currentOptions.find((option) => option.category === "thought_level");
    if (
      requestedThinking !== undefined &&
      thinkingOption &&
      requestedThinking !== currentSelectValue(thinkingOption)
    ) {
      const configId = thinkingOption.id.trim() || "thinking";
      yield* input.runtime.setConfigOption(configId, requestedThinking).pipe(
        Effect.mapError((cause) =>
          input.mapError({
            cause,
            step: "set-config-option",
            configId,
          }),
        ),
      );
    }
  });
}

/**
 * True when a turn is nothing but a slash command invocation.
 *
 * Oh My Pi joins every text block of a prompt with a blank line before it
 * parses the result, and its parser reads everything after the command name
 * as the command's arguments. Appending anything to such a turn silently
 * becomes an argument — `/compact` would compact toward T3's own runtime
 * instructions rather than the conversation.
 */
export function isBareSlashCommand(text: string): boolean {
  const trimmed = text.trim();
  return trimmed.startsWith("/") && !/\s/.test(trimmed);
}
