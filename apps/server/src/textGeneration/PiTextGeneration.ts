/**
<<<<<<< HEAD
 * PiTextGeneration — commit messages, PR content, branch names and thread
 * titles through Pi's one-shot mode.
 *
 * `pi -p` takes the prompt on stdin and writes the reply to stdout, so this
 * needs none of the RPC machinery the session adapter carries.
 *
 * @module textGeneration/PiTextGeneration
 */
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

import { PI_DEFAULT_MODEL, TextGenerationError, type PiSettings } from "@infinitus/contracts";
import { sanitizeBranchFragment, sanitizeFeatureBranchName } from "@infinitus/shared/git";
import { extractJsonObject } from "@infinitus/shared/schemaJson";
import { resolveSpawnCommand } from "@infinitus/shared/shell";

import { expandHomePath } from "../pathExpansion.ts";
import { piHomeEnvironment } from "../provider/Layers/piHomeEnvironment.ts";
import { spawnAndCollect } from "../provider/providerSnapshot.ts";
=======
 * PiTextGeneration — commit messages, PR content, branch names, and thread
 * titles generated through an ephemeral `pi --mode rpc --no-session` process.
 * No session file is written; the user's Pi configuration (default model,
 * auth, custom providers) still applies.
 */
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Queue from "effect/Queue";
import * as Schema from "effect/Schema";
import { ChildProcessSpawner } from "effect/unstable/process";

import { TextGenerationError, type ModelSelection, type PiSettings } from "@infinitus/contracts";
import { formatGeneratedBranchName, sanitizeFeatureBranchName } from "@infinitus/shared/git";
import { extractJsonObject } from "@infinitus/shared/schemaJson";

import { makePiRpcConnection, parsePiModelSlug } from "../orchestration-v2/Adapters/PiRpc.ts";
import {
  buildPiRpcLaunch,
  resolvePiLaunchArgs,
} from "../orchestration-v2/Adapters/piT3McpInjection.ts";
>>>>>>> upstream-sync-781223057-upstream-renamed
import * as TextGeneration from "./TextGeneration.ts";
import {
  buildBranchNamePrompt,
  buildCommitMessagePrompt,
  buildPrContentPrompt,
  buildThreadTitlePrompt,
} from "./TextGenerationPrompts.ts";
import {
  sanitizeCommitSubject,
  sanitizePrTitle,
  sanitizeThreadTitle,
} from "./TextGenerationUtils.ts";

const PI_TIMEOUT_MS = 180_000;

<<<<<<< HEAD
type PiTextGenerationOperation =
  | "generateCommitMessage"
  | "generatePrContent"
  | "generateBranchName"
  | "generateThreadTitle";

/**
 * Flags for a one-shot run.
 *
 * `--no-session` keeps these off Pi's session store. Without it every commit
 * message and thread title we generate is written to `sessions/<cwd>/` exactly
 * like a real conversation, and the project scanner then offers our own
 * internal prompts back to the user as importable history.
 *
 * `--no-tools`: the prompt carries a diff nobody vetted, Pi has no permission
 * gate, and writing a title needs no tool.
 *
 * `pi-default` is our sentinel for "whatever Pi is configured to use", not a
 * slug Pi knows — passing it through fails the process with
 * `Model "pi-default" not found`, so the flag is omitted instead.
 */
export function piTextGenerationArgs(model: string | null | undefined): ReadonlyArray<string> {
  const trimmed = model?.trim();
  return trimmed && trimmed !== PI_DEFAULT_MODEL
    ? ["-p", "--no-session", "--no-tools", "--model", trimmed]
    : ["-p", "--no-session", "--no-tools"];
}

/**
 * Failure detail from a one-shot run.
 *
 * Pi writes a plain message to stderr and exits non-zero (`Error: Model
 * "x" not found. Use --list-models…`). Unlike Oh My Pi it does not paint a
 * `Working...` spinner there, so there is nothing to strip — but the stream
 * is still bounded here, since a stack trace or a chatty extension would
 * otherwise end up whole in an error message shown to the user.
 */
export function piStderrDetail(stderr: string): string | undefined {
  const trimmed = stderr.trim();
  if (trimmed.length === 0) return undefined;
  return trimmed.length > 500 ? `${trimmed.slice(0, 500)}…` : trimmed;
}
=======
const isTextGenerationError = Schema.is(TextGenerationError);
>>>>>>> upstream-sync-781223057-upstream-renamed

export const makePiTextGeneration = Effect.fn("makePiTextGeneration")(function* (
  piSettings: PiSettings,
  environment: NodeJS.ProcessEnv = process.env,
) {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
<<<<<<< HEAD
  // One-shot runs read the same config and credentials a session does, so
  // they get the same home treatment: see `piHomeEnvironment`, which also
  // keeps an ambient Oh My Pi value from redirecting Pi at its directory.
  const env = piHomeEnvironment(environment, piSettings.homePath);
=======
>>>>>>> upstream-sync-781223057-upstream-renamed

  const runPiJson = <S extends Schema.Top>({
    operation,
    cwd,
    prompt,
    outputSchemaJson,
<<<<<<< HEAD
    model,
  }: {
    operation: PiTextGenerationOperation;
    cwd: string;
    prompt: string;
    outputSchemaJson: S;
    model: string | null | undefined;
  }): Effect.Effect<S["Type"], TextGenerationError, S["DecodingServices"]> =>
    Effect.gen(function* () {
      const binaryPath = expandHomePath(piSettings.binaryPath || "pi");
      const args = piTextGenerationArgs(model);
      const spawnCommand = yield* resolveSpawnCommand(binaryPath, args, { env }).pipe(
        Effect.mapError(
          (cause) =>
            new TextGenerationError({
              operation,
              detail: `Failed to resolve the Pi CLI at '${binaryPath}'.`,
              cause,
            }),
        ),
      );

      const output = yield* spawnAndCollect(
        binaryPath,
        ChildProcess.make(spawnCommand.command, spawnCommand.args, {
          cwd,
          env,
          shell: spawnCommand.shell,
          // The prompt goes over stdin, never argv: it carries a diff, and a
          // long or quoted argv is neither portable nor safe to log.
          stdin: { stream: Stream.encodeText(Stream.make(prompt)) },
        }),
      ).pipe(
        Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, spawner),
        Effect.timeoutOption(PI_TIMEOUT_MS),
        Effect.mapError(
          (cause) =>
            new TextGenerationError({ operation, detail: "The Pi CLI failed to run.", cause }),
        ),
        Effect.flatMap(
          Option.match({
            onNone: () =>
              Effect.fail(
                new TextGenerationError({ operation, detail: "The Pi CLI request timed out." }),
              ),
            onSome: Effect.succeed,
          }),
        ),
      );

      if (output.code !== 0) {
        const detail = piStderrDetail(output.stderr);
        return yield* new TextGenerationError({
          operation,
          detail: detail
            ? `Pi exited with code ${output.code}: ${detail}`
            : `Pi exited with code ${output.code}.`,
        });
      }

      const trimmed = output.stdout.trim();
      if (trimmed.length === 0) {
        const detail = piStderrDetail(output.stderr);
        return yield* new TextGenerationError({
          operation,
          detail: detail ? `Pi returned no output: ${detail}` : "Pi returned empty output.",
        });
      }

      const decodeOutput = Schema.decodeEffect(Schema.fromJsonString(outputSchemaJson));
      return yield* decodeOutput(extractJsonObject(trimmed)).pipe(
=======
    modelSelection,
  }: {
    operation:
      | "generateCommitMessage"
      | "generatePrContent"
      | "generateBranchName"
      | "generateThreadTitle";
    cwd: string;
    prompt: string;
    outputSchemaJson: S;
    modelSelection: ModelSelection;
  }): Effect.Effect<S["Type"], TextGenerationError, S["DecodingServices"]> =>
    Effect.gen(function* () {
      const resolvedLaunchArgs = resolvePiLaunchArgs(piSettings.launchArgs);
      if (!resolvedLaunchArgs.ok) {
        return yield* new TextGenerationError({
          operation,
          detail: resolvedLaunchArgs.message,
        });
      }
      const launch = buildPiRpcLaunch({
        launchArgs: resolvedLaunchArgs.args,
        environment,
        mcpSession: undefined,
        extensionPath: undefined,
        ephemeral: true,
        // No user is present to answer a text-generation extension dialog.
        disableExtensions: true,
        // Background naming/content helpers must never mutate the workspace.
        disableTools: true,
      });
      const connection = yield* makePiRpcConnection({
        command: piSettings.binaryPath || "pi",
        // Extensions and tools are disabled because no user is present to
        // answer a dialog and background text generation is read-only. User
        // model config and auth still apply.
        args: launch.args,
        cwd,
        env: launch.env,
      }).pipe(Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, spawner));

      if (modelSelection.model !== "default") {
        // `customModels` accepts arbitrary strings, so an unusable slug is
        // rejected rather than skipped: running Pi's default model here would
        // report success for a model the caller never asked for.
        const parsed = parsePiModelSlug(modelSelection.model);
        if (parsed === null) {
          return yield* new TextGenerationError({
            operation,
            detail: `Pi model '${modelSelection.model}' must use provider/model format.`,
          });
        }
        yield* connection.request({
          type: "set_model",
          provider: parsed.provider,
          modelId: parsed.modelId,
        });
      }

      yield* connection.request({ type: "prompt", message: prompt });
      yield* Effect.gen(function* () {
        while (true) {
          const event = yield* Queue.take(connection.events);
          if (event["type"] === "agent_settled") return;
        }
      });
      const data = yield* connection.request({ type: "get_last_assistant_text" });
      const text =
        typeof data === "object" &&
        data !== null &&
        typeof (data as { text?: unknown }).text === "string"
          ? (data as { text: string }).text.trim()
          : "";
      if (!text) {
        return yield* new TextGenerationError({
          operation,
          detail: "Pi returned empty output.",
        });
      }
      const decodeOutput = Schema.decodeEffect(Schema.fromJsonString(outputSchemaJson));
      return yield* decodeOutput(extractJsonObject(text)).pipe(
>>>>>>> upstream-sync-781223057-upstream-renamed
        Effect.catchTags({
          SchemaError: (cause) =>
            Effect.fail(
              new TextGenerationError({
                operation,
                detail: "Pi returned invalid structured output.",
                cause,
              }),
            ),
        }),
      );
<<<<<<< HEAD
    });
=======
    }).pipe(
      Effect.timeoutOption(PI_TIMEOUT_MS),
      Effect.flatMap(
        Option.match({
          onNone: () =>
            Effect.fail(new TextGenerationError({ operation, detail: "Pi request timed out." })),
          onSome: (value) => Effect.succeed(value),
        }),
      ),
      Effect.mapError((cause) =>
        isTextGenerationError(cause)
          ? cause
          : new TextGenerationError({
              operation,
              detail: "Pi text generation failed.",
              cause,
            }),
      ),
      Effect.scoped,
    );
>>>>>>> upstream-sync-781223057-upstream-renamed

  const generateCommitMessage: TextGeneration.TextGeneration["Service"]["generateCommitMessage"] =
    Effect.fn("PiTextGeneration.generateCommitMessage")(function* (input) {
      const { prompt, outputSchema } = buildCommitMessagePrompt({
        branch: input.branch,
        stagedSummary: input.stagedSummary,
        stagedPatch: input.stagedPatch,
        includeBranch: input.includeBranch === true,
        policy: input.policy,
      });
      const generated = yield* runPiJson({
        operation: "generateCommitMessage",
        cwd: input.cwd,
        prompt,
        outputSchemaJson: outputSchema,
<<<<<<< HEAD
        model: input.modelSelection.model,
=======
        modelSelection: input.modelSelection,
>>>>>>> upstream-sync-781223057-upstream-renamed
      });
      return {
        subject: sanitizeCommitSubject(generated.subject),
        body: generated.body.trim(),
        ...("branch" in generated && typeof generated.branch === "string"
          ? { branch: sanitizeFeatureBranchName(generated.branch) }
          : {}),
      };
    });

  const generatePrContent: TextGeneration.TextGeneration["Service"]["generatePrContent"] =
    Effect.fn("PiTextGeneration.generatePrContent")(function* (input) {
      const { prompt, outputSchema } = buildPrContentPrompt({
        baseBranch: input.baseBranch,
        headBranch: input.headBranch,
        commitSummary: input.commitSummary,
        diffSummary: input.diffSummary,
        diffPatch: input.diffPatch,
        policy: input.policy,
        changeRequestTemplate: input.changeRequestTemplate,
      });
      const generated = yield* runPiJson({
        operation: "generatePrContent",
        cwd: input.cwd,
        prompt,
        outputSchemaJson: outputSchema,
<<<<<<< HEAD
        model: input.modelSelection.model,
      });
      return { title: sanitizePrTitle(generated.title), body: generated.body.trim() };
=======
        modelSelection: input.modelSelection,
      });
      return {
        title: sanitizePrTitle(generated.title),
        body: generated.body.trim(),
      };
>>>>>>> upstream-sync-781223057-upstream-renamed
    });

  const generateBranchName: TextGeneration.TextGeneration["Service"]["generateBranchName"] =
    Effect.fn("PiTextGeneration.generateBranchName")(function* (input) {
      const { prompt, outputSchema } = buildBranchNamePrompt({
        message: input.message,
        attachments: input.attachments,
<<<<<<< HEAD
=======
        naming: input.naming,
>>>>>>> upstream-sync-781223057-upstream-renamed
      });
      const generated = yield* runPiJson({
        operation: "generateBranchName",
        cwd: input.cwd,
        prompt,
        outputSchemaJson: outputSchema,
<<<<<<< HEAD
        model: input.modelSelection.model,
      });
      return { branch: sanitizeBranchFragment(generated.branch) };
=======
        modelSelection: input.modelSelection,
      });
      return {
        branch: formatGeneratedBranchName(generated.branch, input.naming),
      };
>>>>>>> upstream-sync-781223057-upstream-renamed
    });

  const generateThreadTitle: TextGeneration.TextGeneration["Service"]["generateThreadTitle"] =
    Effect.fn("PiTextGeneration.generateThreadTitle")(function* (input) {
      const { prompt, outputSchema } = buildThreadTitlePrompt({
        message: input.message,
        previousTitle: input.previousTitle,
<<<<<<< HEAD
        linkedContext: input.linkedContext,
=======
>>>>>>> upstream-sync-781223057-upstream-renamed
        attachments: input.attachments,
      });
      const generated = yield* runPiJson({
        operation: "generateThreadTitle",
        cwd: input.cwd,
        prompt,
        outputSchemaJson: outputSchema,
<<<<<<< HEAD
        model: input.modelSelection.model,
      });
      return {
        title: sanitizeThreadTitle(generated.title),
        ...(generated.needsRefinement ? { needsRefinement: true } : {}),
=======
        modelSelection: input.modelSelection,
      });
      return {
        title: sanitizeThreadTitle(generated.title),
>>>>>>> upstream-sync-781223057-upstream-renamed
      } satisfies TextGeneration.ThreadTitleGenerationResult;
    });

  return {
    generateCommitMessage,
    generatePrContent,
    generateBranchName,
    generateThreadTitle,
  } satisfies TextGeneration.TextGeneration["Service"];
});
