/**
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

export const makePiTextGeneration = Effect.fn("makePiTextGeneration")(function* (
  piSettings: PiSettings,
  environment: NodeJS.ProcessEnv = process.env,
) {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  // One-shot runs read the same config and credentials a session does, so
  // they get the same home treatment: see `piHomeEnvironment`, which also
  // keeps an ambient Oh My Pi value from redirecting Pi at its directory.
  const env = piHomeEnvironment(environment, piSettings.homePath);

  const runPiJson = <S extends Schema.Top>({
    operation,
    cwd,
    prompt,
    outputSchemaJson,
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
    });

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
        model: input.modelSelection.model,
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
        model: input.modelSelection.model,
      });
      return { title: sanitizePrTitle(generated.title), body: generated.body.trim() };
    });

  const generateBranchName: TextGeneration.TextGeneration["Service"]["generateBranchName"] =
    Effect.fn("PiTextGeneration.generateBranchName")(function* (input) {
      const { prompt, outputSchema } = buildBranchNamePrompt({
        message: input.message,
        attachments: input.attachments,
      });
      const generated = yield* runPiJson({
        operation: "generateBranchName",
        cwd: input.cwd,
        prompt,
        outputSchemaJson: outputSchema,
        model: input.modelSelection.model,
      });
      return { branch: sanitizeBranchFragment(generated.branch) };
    });

  const generateThreadTitle: TextGeneration.TextGeneration["Service"]["generateThreadTitle"] =
    Effect.fn("PiTextGeneration.generateThreadTitle")(function* (input) {
      const { prompt, outputSchema } = buildThreadTitlePrompt({
        message: input.message,
        previousTitle: input.previousTitle,
        linkedContext: input.linkedContext,
        attachments: input.attachments,
      });
      const generated = yield* runPiJson({
        operation: "generateThreadTitle",
        cwd: input.cwd,
        prompt,
        outputSchemaJson: outputSchema,
        model: input.modelSelection.model,
      });
      return {
        title: sanitizeThreadTitle(generated.title),
        ...(generated.needsRefinement ? { needsRefinement: true } : {}),
      } satisfies TextGeneration.ThreadTitleGenerationResult;
    });

  return {
    generateCommitMessage,
    generatePrContent,
    generateBranchName,
    generateThreadTitle,
  } satisfies TextGeneration.TextGeneration["Service"];
});
