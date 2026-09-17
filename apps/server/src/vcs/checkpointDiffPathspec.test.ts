import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import { assert, it } from "@effect/vitest";

import { CheckpointRef } from "@infinitus/contracts";
import * as ServerConfig from "../config.ts";
import * as GitVcsDriver from "./GitVcsDriver.ts";
import * as VcsProcess from "./VcsProcess.ts";

const TestLayer = Layer.mergeAll(GitVcsDriver.vcsLayer, GitVcsDriver.layer).pipe(
  Layer.provide(ServerConfig.layerTest(process.cwd(), { prefix: "t3-checkpoint-base-" })),
  Layer.provideMerge(VcsProcess.layer),
  Layer.provideMerge(NodeServices.layer),
);

const FROM = CheckpointRef.make("refs/t3/checkpoints/turns/0");
const TO = CheckpointRef.make("refs/t3/checkpoints/turns/1");

/**
 * A feature branch off main, a turn-0 checkpoint, then main moves ahead
 * (upstream.txt) and the branch is rebased onto it while the agent edits
 * agent.txt, then a turn-1 checkpoint.
 */
const makeRebasedTurn = Effect.fn("makeRebasedTurn")(function* (branch: string) {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const driver = yield* GitVcsDriver.makeVcsDriverShape();
  const cwd = yield* fileSystem.makeTempDirectoryScoped({ prefix: "t3-checkpoint-rebase-" });
  const git = (args: ReadonlyArray<string>) =>
    driver.execute({ operation: "checkpoint-base-test", cwd, args });
  const write = (name: string, contents: string) =>
    fileSystem.writeFileString(path.join(cwd, name), contents);

  yield* git(["init", "--initial-branch=main"]);
  yield* git(["config", "user.name", "Test"]);
  yield* git(["config", "user.email", "test@test.com"]);
  yield* write("agent.txt", "initial\n");
  yield* write("upstream.txt", "initial\n");
  yield* git(["add", "."]);
  yield* git(["commit", "-m", "initial"]);
  if (branch !== "main") {
    yield* git(["checkout", "-b", branch]);
  }
  yield* driver.checkpoints.captureCheckpoint({ cwd, checkpointRef: FROM });

  yield* git(["checkout", "main"]);
  yield* write("upstream.txt", "landed on main\n");
  yield* git(["commit", "-am", "upstream change"]);
  yield* git(["checkout", branch]);
  if (branch !== "main") {
    yield* git(["rebase", "main"]);
  }
  yield* write("agent.txt", "edited by the agent\n");
  yield* driver.checkpoints.captureCheckpoint({ cwd, checkpointRef: TO });

  return { driver, cwd, git };
});

it.effect("a rebase inside the turn is not attributed to the turn", () =>
  Effect.gen(function* () {
    const { driver, cwd } = yield* makeRebasedTurn("feature");

    const numstat = yield* driver.checkpoints.diffCheckpoints({
      cwd,
      fromCheckpointRef: FROM,
      toCheckpointRef: TO,
      ignoreWhitespace: false,
      format: "numstat",
    });
    assert.deepEqual(numstat.split("\0").filter(Boolean), ["1\t1\tagent.txt"]);

    const patch = yield* driver.checkpoints.diffCheckpoints({
      cwd,
      fromCheckpointRef: FROM,
      toCheckpointRef: TO,
      ignoreWhitespace: false,
    });
    assert.include(patch, "diff --git a/agent.txt b/agent.txt");
    assert.notInclude(patch, "upstream.txt");
  }).pipe(Effect.scoped, Effect.provide(TestLayer)),
);

it.effect("a turn that only pulls in the base diffs to nothing", () =>
  Effect.gen(function* () {
    const { driver, cwd, git } = yield* makeRebasedTurn("feature");
    yield* git(["checkout", TO, "--", "upstream.txt"]);
    yield* git(["checkout", FROM, "--", "agent.txt"]);
    yield* git(["reset", "--quiet"]);
    const onlyRebase = CheckpointRef.make("refs/t3/checkpoints/turns/2");
    yield* driver.checkpoints.captureCheckpoint({ cwd, checkpointRef: onlyRebase });

    const patch = yield* driver.checkpoints.diffCheckpoints({
      cwd,
      fromCheckpointRef: FROM,
      toCheckpointRef: onlyRebase,
      ignoreWhitespace: false,
    });
    assert.strictEqual(patch, "");
  }).pipe(Effect.scoped, Effect.provide(TestLayer)),
);

it.effect("a thread on the base branch itself keeps the unrestricted diff", () =>
  Effect.gen(function* () {
    const { driver, cwd } = yield* makeRebasedTurn("main");

    const numstat = yield* driver.checkpoints.diffCheckpoints({
      cwd,
      fromCheckpointRef: FROM,
      toCheckpointRef: TO,
      ignoreWhitespace: false,
      format: "numstat",
    });
    assert.deepEqual(numstat.split("\0").filter(Boolean), [
      "1\t1\tagent.txt",
      "1\t1\tupstream.txt",
    ]);
  }).pipe(Effect.scoped, Effect.provide(TestLayer)),
);
