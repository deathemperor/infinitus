import * as NodeServices from "@effect/platform-node/NodeServices";
import { expect, it } from "@effect/vitest";
import { OmpSettings, ProviderInstanceId, TextGenerationError } from "@infinitus/contracts";
import { createModelSelection } from "@infinitus/shared/model";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";

import * as ServerConfig from "../config.ts";
import { writeFakeCli } from "../testUtils/fakeCli.ts";
import * as TextGeneration from "./TextGeneration.ts";
import { makeOmpTextGeneration } from "./OmpTextGeneration.ts";

const decodeOmpSettings = Schema.decodeSync(OmpSettings);
const decodeArgv = Schema.decodeEffect(Schema.fromJsonString(Schema.Array(Schema.String)));

const DEFAULT_TEST_MODEL_SELECTION = createModelSelection(
  ProviderInstanceId.make("omp"),
  "google-antigravity/gemini-3.1-pro",
);

const OmpTextGenerationTestLayer = ServerConfig.ServerConfig.layerTest(process.cwd(), {
  prefix: "t3code-omp-text-generation-test-",
}).pipe(Layer.provideMerge(NodeServices.layer));

interface FakeOmpInput {
  output: string;
  exitCode?: number;
  stderr?: string;
}

function makeFakeOmpBinary(dir: string, input: FakeOmpInput) {
  const check = JSON.stringify({
    stderr: input.stderr ?? null,
    output: input.output,
    exitCode: input.exitCode ?? 0,
  });
  return Effect.gen(function* () {
    const path = yield* Path.Path;
    return writeFakeCli({
      directory: path.join(dir, "bin"),
      name: "omp",
      source: [
        `const check = ${check};`,
        "const args = process.argv.slice(2);",
        'const originalArgs = ` ${args.join(" ")} `;',
        "function fail(message, code) {",
        '  process.stderr.write(message + "\\n");',
        "  process.exit(code);",
        "}",
        'if (!originalArgs.includes(" -p ")) fail("missing -p", 11);',
        'if (!originalArgs.includes(" --no-tools ")) fail("missing --no-tools", 12);',
        'if (!originalArgs.includes(" --no-session ")) fail("missing --no-session", 13);',
        'if (!originalArgs.includes(" --no-title ")) fail("missing --no-title", 14);',
        'if (!originalArgs.includes(" --model ")) fail("missing --model", 15);',
        'if (originalArgs.includes(" --mode ")) fail("must not use --mode", 16);',
        "const chunks = [];",
        "for await (const chunk of process.stdin) chunks.push(chunk);",
        "if (check.stderr !== null) process.stderr.write(check.stderr);",
        "process.stdout.write(check.output);",
        "process.exitCode = check.exitCode;",
        "",
      ].join("\n"),
    });
  });
}

/**
 * A fake omp that refuses `--model omp-default` the way the real binary does
 * ("Model \"omp-default\" not found") and writes its argv where the test can
 * read it. `makeFakeOmpBinary` REQUIRES `--model`, so it cannot catch a run
 * that should omit the flag.
 */
function makeModelRecordingOmpBinary(dir: string, argvPath: string) {
  return Effect.gen(function* () {
    const path = yield* Path.Path;
    return writeFakeCli({
      directory: path.join(dir, "bin"),
      name: "omp",
      source: [
        "import * as fs from 'node:fs';",
        "const args = process.argv.slice(2);",
        // Generated stub source, not Effect runtime code; the file it writes is
        // read back through Schema below.
        // @effect-diagnostics-next-line preferSchemaOverJson:off
        `fs.writeFileSync(${JSON.stringify(argvPath)}, JSON.stringify(args));`,
        "const i = args.indexOf('--model');",
        "if (i !== -1 && args[i + 1] === 'omp-default') {",
        "  process.stderr.write('Model \"omp-default\" not found\\n');",
        "  process.exit(1);",
        "}",
        "const chunks = [];",
        "for await (const chunk of process.stdin) chunks.push(chunk);",
        "process.stderr.write('Working...\\n');",
        "process.stdout.write(JSON.stringify({ title: 'Ok' }));",
        "",
      ].join("\n"),
    });
  });
}

function withFakeOmpEnv<A, E, R>(
  input: FakeOmpInput,
  effectFn: (textGeneration: TextGeneration.TextGeneration["Service"]) => Effect.Effect<A, E, R>,
) {
  return Effect.gen(function* () {
    const fs = yield* FileSystem.FileSystem;
    const tempDir = yield* fs.makeTempDirectoryScoped({ prefix: "t3code-omp-text-" });
    const ompPath = yield* makeFakeOmpBinary(tempDir, input);
    const config = decodeOmpSettings({ binaryPath: ompPath });
    const textGeneration = yield* makeOmpTextGeneration(config);
    return yield* effectFn(textGeneration);
  }).pipe(Effect.scoped);
}

it.layer(OmpTextGenerationTestLayer)("OmpTextGeneration", (it) => {
  // Found by running the real binary: `resolveOmpAcpBaseModelId` answers the
  // `omp-default` sentinel when nothing is chosen, and `omp -p` has no session
  // to read it from, so passing it as `--model` failed every generation.
  it.effect("omits --model when the selection is the omp-default sentinel", () =>
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const tempDir = yield* fs.makeTempDirectoryScoped({ prefix: "t3code-omp-model-" });
      const argvPath = path.join(tempDir, "argv.json");
      const ompPath = yield* makeModelRecordingOmpBinary(tempDir, argvPath);
      const textGeneration = yield* makeOmpTextGeneration(
        decodeOmpSettings({ binaryPath: ompPath }),
      );

      const generated = yield* textGeneration.generateThreadTitle({
        cwd: process.cwd(),
        message: "a thread about nothing in particular",
        modelSelection: createModelSelection(ProviderInstanceId.make("omp"), "omp-default"),
      });
      expect(generated.title).toBe("Ok");

      const argv = yield* decodeArgv(yield* fs.readFileString(argvPath));
      expect(argv).not.toContain("--model");
      expect(argv).toContain("-p");
    }).pipe(Effect.scoped),
  );

  it.effect("passes --model through when a real model is selected", () =>
    Effect.gen(function* () {
      const fs = yield* FileSystem.FileSystem;
      const path = yield* Path.Path;
      const tempDir = yield* fs.makeTempDirectoryScoped({ prefix: "t3code-omp-model-" });
      const argvPath = path.join(tempDir, "argv.json");
      const ompPath = yield* makeModelRecordingOmpBinary(tempDir, argvPath);
      const textGeneration = yield* makeOmpTextGeneration(
        decodeOmpSettings({ binaryPath: ompPath }),
      );

      yield* textGeneration.generateThreadTitle({
        cwd: process.cwd(),
        message: "a thread about nothing in particular",
        modelSelection: DEFAULT_TEST_MODEL_SELECTION,
      });

      const argv = yield* decodeArgv(yield* fs.readFileString(argvPath));
      const modelIndex = argv.indexOf("--model");
      expect(modelIndex).toBeGreaterThanOrEqual(0);
      expect(argv[modelIndex + 1]).toBe("google-antigravity/gemini-3.1-pro");
    }).pipe(Effect.scoped),
  );

  it.effect("decodes a well-formed commit message JSON answer", () =>
    withFakeOmpEnv(
      {
        output: JSON.stringify({
          subject: "Add Oh My Pi text generation",
          body: "- spawn omp -p\n- extract JSON from free text",
        }),
        stderr: "Working...\n",
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const generated = yield* textGeneration.generateCommitMessage({
            cwd: process.cwd(),
            branch: "feat/omp-text",
            stagedSummary: "M apps/server/src/textGeneration/OmpTextGeneration.ts",
            stagedPatch: "diff --git a/OmpTextGeneration.ts b/OmpTextGeneration.ts",
            modelSelection: DEFAULT_TEST_MODEL_SELECTION,
          });
          expect(generated.subject).toBe("Add Oh My Pi text generation");
          expect(generated.body).toBe("- spawn omp -p\n- extract JSON from free text");
        }),
    ),
  );

  it.effect("decodes a well-formed PR content JSON answer", () =>
    withFakeOmpEnv(
      {
        output: JSON.stringify({
          title: "feat(server): generate text with Oh My Pi",
          body: "## Summary\n- Replace the omp stub.\n\n## Testing\n- Fake CLI covers the four operations.",
        }),
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const generated = yield* textGeneration.generatePrContent({
            cwd: process.cwd(),
            baseBranch: "main",
            headBranch: "feat/omp-text",
            commitSummary: "feat: generate text with Oh My Pi",
            diffSummary: "M apps/server/src/textGeneration/OmpTextGeneration.ts",
            diffPatch: "diff --git a/OmpTextGeneration.ts b/OmpTextGeneration.ts",
            modelSelection: DEFAULT_TEST_MODEL_SELECTION,
          });
          expect(generated.title).toBe("feat(server): generate text with Oh My Pi");
          expect(generated.body).toContain("Replace the omp stub.");
        }),
    ),
  );

  it.effect("decodes a well-formed branch name JSON answer", () =>
    withFakeOmpEnv(
      {
        output: JSON.stringify({ branch: "omp text generation" }),
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const generated = yield* textGeneration.generateBranchName({
            cwd: process.cwd(),
            message: "wire up omp -p for titles and commit messages",
            modelSelection: DEFAULT_TEST_MODEL_SELECTION,
          });
          expect(generated.branch).toBe("omp-text-generation");
        }),
    ),
  );

  it.effect("decodes a well-formed thread title JSON answer", () =>
    withFakeOmpEnv(
      {
        output: JSON.stringify({ title: "Generate text with Oh My Pi" }),
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const generated = yield* textGeneration.generateThreadTitle({
            cwd: process.cwd(),
            message: "titles and commit messages should work on omp",
            modelSelection: DEFAULT_TEST_MODEL_SELECTION,
          });
          expect(generated.title).toBe("Generate text with Oh My Pi");
        }),
    ),
  );

  it.effect("extracts JSON when the answer is fenced and wrapped in prose", () =>
    withFakeOmpEnv(
      {
        output:
          "Sure, here is the JSON:\n```json\n" +
          JSON.stringify({
            subject: "Tighten Oh My Pi parsing",
            body: "Handle fenced JSON text output.",
          }) +
          "\n```\nDone.",
        stderr: "Working...\n",
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const generated = yield* textGeneration.generateCommitMessage({
            cwd: process.cwd(),
            branch: "feat/omp-text",
            stagedSummary: "M README.md",
            stagedPatch: "diff --git a/README.md b/README.md",
            modelSelection: DEFAULT_TEST_MODEL_SELECTION,
          });
          expect(generated.subject).toBe("Tighten Oh My Pi parsing");
          expect(generated.body).toBe("Handle fenced JSON text output.");
        }),
    ),
  );

  it.effect("reports the real stderr detail on a non-zero exit", () =>
    withFakeOmpEnv(
      {
        output: JSON.stringify({ subject: "ignored", body: "" }),
        exitCode: 1,
        stderr: "Working...\nomp: model not found\n",
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const error = yield* textGeneration
            .generateCommitMessage({
              cwd: process.cwd(),
              branch: "feat/omp-text",
              stagedSummary: "M README.md",
              stagedPatch: "diff --git a/README.md b/README.md",
              modelSelection: DEFAULT_TEST_MODEL_SELECTION,
            })
            .pipe(Effect.flip);

          expect(error).toBeInstanceOf(TextGenerationError);
          expect(error.detail).toContain("omp: model not found");
          expect(error.detail).not.toContain("Working...");
        }),
    ),
  );

  it.effect("does not report Working... as the detail when stderr is only the spinner", () =>
    withFakeOmpEnv(
      {
        output: "auth required: run omp once to sign in",
        exitCode: 1,
        stderr: "Working...\n",
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const error = yield* textGeneration
            .generateThreadTitle({
              cwd: process.cwd(),
              message: "anything",
              modelSelection: DEFAULT_TEST_MODEL_SELECTION,
            })
            .pipe(Effect.flip);

          expect(error).toBeInstanceOf(TextGenerationError);
          expect(error.detail).toContain("auth required: run omp once to sign in");
          expect(error.detail).not.toContain("Working...");
        }),
    ),
  );

  it.effect("fails as TextGenerationError when the answer is not JSON", () =>
    withFakeOmpEnv(
      {
        output: "totally not json output from a confused model",
        stderr: "Working...\n",
      },
      (textGeneration) =>
        Effect.gen(function* () {
          const result = yield* textGeneration
            .generateThreadTitle({
              cwd: process.cwd(),
              message: "anything",
              modelSelection: DEFAULT_TEST_MODEL_SELECTION,
            })
            .pipe(Effect.result);

          expect(Result.isFailure(result)).toBe(true);
          if (Result.isFailure(result)) {
            expect(result.failure).toBeInstanceOf(TextGenerationError);
            expect(result.failure.detail).toMatch(/invalid structured output/i);
          }
        }),
    ),
  );
});
