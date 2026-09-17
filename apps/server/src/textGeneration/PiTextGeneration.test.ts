// @effect-diagnostics nodeBuiltinImport:off - builds a fake `pi` CLI in a temp dir.
import * as NodePath from "node:path";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import { PI_DEFAULT_MODEL, PiSettings, ProviderInstanceId } from "@infinitus/contracts";
import { createModelSelection } from "@infinitus/shared/model";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";

import { writeFakeCli } from "../testUtils/fakeCli.ts";
import { makePiTextGeneration, piStderrDetail, piTextGenerationArgs } from "./PiTextGeneration.ts";

const decodePiSettings = Schema.decodeSync(PiSettings);

describe("piTextGenerationArgs", () => {
  it("keeps one-shot runs out of Pi's session store", () => {
    // Without `--no-session` every generated commit message and thread title
    // lands in `sessions/<cwd>/` like a real conversation, and the project
    // scanner then offers our own internal prompts back as importable history.
    expect(piTextGenerationArgs(null)).toContain("--no-session");
    expect(piTextGenerationArgs("openai/gpt-5")).toContain("--no-session");
  });

  it("omits the sentinel default model, which Pi does not know", () => {
    expect(piTextGenerationArgs(PI_DEFAULT_MODEL)).toEqual(["-p", "--no-session", "--no-tools"]);
    expect(piTextGenerationArgs("  ")).toEqual(["-p", "--no-session", "--no-tools"]);
  });

  it("passes a real model through", () => {
    expect(piTextGenerationArgs("zai/glm-5.3")).toEqual([
      "-p",
      "--no-session",
      "--no-tools",
      "--model",
      "zai/glm-5.3",
    ]);
  });
});

describe("piStderrDetail", () => {
  it("drops empty stderr and bounds a long one", () => {
    expect(piStderrDetail("   \n ")).toBeUndefined();
    expect(piStderrDetail(' Error: Model "x" not found ')).toBe('Error: Model "x" not found');
    const long = piStderrDetail("x".repeat(900));
    expect(long).toHaveLength(501);
    expect(long?.endsWith("…")).toBe(true);
  });
});

it.layer(NodeServices.layer)("makePiTextGeneration", (it) => {
  it.effect("runs one-shot generations in the instance's home, not an ambient one", () =>
    Effect.gen(function* () {
      // `pi -p` reads the same credentials and config a session does. An
      // ambient `PI_CODING_AGENT_DIR` here is usually Oh My Pi's: Oh My Pi is
      // a fork of Pi that kept `APP_NAME = "pi"`, so both derive this name.
      const fileSystem = yield* FileSystem.FileSystem;
      const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-textgen-home-" });
      const homeLogPath = NodePath.join(directory, "home.txt");
      const binaryPath = writeFakeCli({
        directory,
        name: "pi",
        // The log path rides in the stub's own env sidecar rather than
        // being quoted into its source.
        env: { PI_HOME_LOG_PATH: homeLogPath },
        source: [
          'import { writeFileSync as writeHomeLog } from "node:fs";',
          'writeHomeLog(process.env.PI_HOME_LOG_PATH, process.env.PI_CODING_AGENT_DIR ?? "");',
          'process.stdout.write(\'{"title":"A title","needsRefinement":false}\');',
          "process.exit(0);",
        ].join("\n"),
      });

      const textGeneration = yield* makePiTextGeneration(
        decodePiSettings({ enabled: true, binaryPath, homePath: "/pi/home" }),
        { ...process.env, PI_CODING_AGENT_DIR: "/omp/home" },
      );
      yield* textGeneration.generateThreadTitle({
        cwd: directory,
        message: "hello",
        modelSelection: createModelSelection(ProviderInstanceId.make("pi"), PI_DEFAULT_MODEL),
      });

      expect(yield* fileSystem.readFileString(homeLogPath)).toBe("/pi/home");
    }),
  );
});
