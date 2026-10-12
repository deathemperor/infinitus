// The fork's worktree cleanup and seeding cases (#270 A), beside upstream's
// `GitVcsDriverCore.test.ts`; the fixtures are copies of that file's. Rules
// and traps: `docs/internals/worktree-cleanup.md`.
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as PlatformError from "effect/PlatformError";
import * as Scope from "effect/Scope";

import type { GitCommandError } from "@infinitus/contracts";
import * as ServerConfig from "../config.ts";
import * as GitVcsDriver from "./GitVcsDriver.ts";

const layerServerConfig = ServerConfig.layerTest(process.cwd(), {
  prefix: "t3-git-vcs-driver-infinitus-test-",
});
const layerTest = GitVcsDriver.layer.pipe(
  Layer.provide(layerServerConfig),
  Layer.provideMerge(NodeServices.layer),
);

const makeTmpDir = (
  prefix = "git-vcs-driver-test-",
): Effect.Effect<string, PlatformError.PlatformError, FileSystem.FileSystem | Scope.Scope> =>
  Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    return yield* fileSystem.makeTempDirectoryScoped({ prefix });
  });

const writeTextFile = (
  cwd: string,
  relativePath: string,
  contents: string,
): Effect.Effect<void, PlatformError.PlatformError, FileSystem.FileSystem | Path.Path> =>
  Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const pathService = yield* Path.Path;
    const filePath = pathService.join(cwd, relativePath);
    yield* fileSystem.makeDirectory(pathService.dirname(filePath), { recursive: true });
    yield* fileSystem.writeFileString(filePath, contents);
  });
const git = (
  cwd: string,
  args: ReadonlyArray<string>,
  env?: NodeJS.ProcessEnv,
): Effect.Effect<string, GitCommandError, GitVcsDriver.GitVcsDriver> =>
  Effect.gen(function* () {
    const driver = yield* GitVcsDriver.GitVcsDriver;
    const result = yield* driver.execute({
      operation: "GitVcsDriver.test.git",
      cwd,
      args,
      ...(env ? { env } : {}),
      timeoutMs: 10_000,
    });
    return result.stdout.trim();
  });

const initRepoWithCommit = (
  cwd: string,
): Effect.Effect<
  { readonly initialBranch: string },
  GitCommandError | PlatformError.PlatformError,
  GitVcsDriver.GitVcsDriver | FileSystem.FileSystem | Path.Path
> =>
  Effect.gen(function* () {
    const driver = yield* GitVcsDriver.GitVcsDriver;
    yield* driver.initRepo({ cwd });
    yield* git(cwd, ["config", "user.email", "test@test.com"]);
    yield* git(cwd, ["config", "user.name", "Test"]);
    yield* writeTextFile(cwd, "README.md", "# test\n");
    yield* git(cwd, ["add", "."]);
    yield* git(cwd, ["commit", "-m", "initial commit"]);
    const initialBranch = yield* git(cwd, ["branch", "--show-current"]);
    return { initialBranch };
  });

it.layer(layerTest)("GitVcsDriver worktree cleanup and seeding", (it) => {
  describe("worktrees", () => {
    it.effect(
      "commits uncommitted work to the worktree's branch before a forced removal (#270 A)",
      () =>
        Effect.gen(function* () {
          const cwd = yield* makeTmpDir();
          const { initialBranch } = yield* initRepoWithCommit(cwd);
          const pathService = yield* Path.Path;
          const fileSystem = yield* FileSystem.FileSystem;
          const worktreePath = pathService.join(yield* makeTmpDir("git-worktrees-"), "wip");
          const driver = yield* GitVcsDriver.GitVcsDriver;
          yield* driver.createWorktree({
            cwd,
            path: worktreePath,
            refName: initialBranch,
            newRefName: "feature/wip",
          });
          yield* writeTextFile(worktreePath, "notes.md", "half done\n");
          yield* writeTextFile(worktreePath, "README.md", "# changed\n");

          const result = yield* driver.removeWorktree({
            cwd,
            path: worktreePath,
            force: true,
            keepWork: true,
            // Asked for, but the branch now holds the only copy of the work.
            deleteBranch: true,
          });

          assert.equal(yield* fileSystem.exists(worktreePath), false);
          assert.equal(result.branch, "feature/wip");
          assert.isNotNull(result.savedWorkCommit);
          assert.equal(result.branchDeleted, false);
          assert.equal(
            yield* git(cwd, ["log", "-1", "--format=%s", "feature/wip"]),
            "wip: work saved when the thread was deleted",
          );
          assert.equal(yield* git(cwd, ["show", "feature/wip:notes.md"]), "half done");
          assert.equal(yield* git(cwd, ["show", "feature/wip:README.md"]), "# changed");
        }),
    );

    it.effect("deletes the branch of a clean worktree only when asked (#270 A)", () =>
      Effect.gen(function* () {
        const cwd = yield* makeTmpDir();
        const { initialBranch } = yield* initRepoWithCommit(cwd);
        const pathService = yield* Path.Path;
        const worktreesRoot = yield* makeTmpDir("git-worktrees-");
        const driver = yield* GitVcsDriver.GitVcsDriver;
        for (const name of ["kept", "dropped"]) {
          yield* driver.createWorktree({
            cwd,
            path: pathService.join(worktreesRoot, name),
            refName: initialBranch,
            newRefName: `feature/${name}`,
          });
        }

        const kept = yield* driver.removeWorktree({
          cwd,
          path: pathService.join(worktreesRoot, "kept"),
          force: true,
          keepWork: true,
        });
        const dropped = yield* driver.removeWorktree({
          cwd,
          path: pathService.join(worktreesRoot, "dropped"),
          force: true,
          keepWork: true,
          deleteBranch: true,
        });

        assert.deepStrictEqual(kept, {
          branch: "feature/kept",
          savedWorkCommit: null,
          branchDeleted: false,
        });
        assert.deepStrictEqual(dropped, {
          branch: "feature/dropped",
          savedWorkCommit: null,
          branchDeleted: true,
        });
        const branches = yield* git(cwd, [
          "branch",
          "--list",
          "feature/*",
          "--format=%(refname:short)",
        ]);
        assert.equal(branches, "feature/kept");
      }),
    );

    it.effect("seeds a new worktree with the files .worktreeinclude names (#270 A)", () =>
      Effect.gen(function* () {
        const cwd = yield* makeTmpDir();
        const { initialBranch } = yield* initRepoWithCommit(cwd);
        const pathService = yield* Path.Path;
        const fileSystem = yield* FileSystem.FileSystem;
        const driver = yield* GitVcsDriver.GitVcsDriver;
        yield* writeTextFile(cwd, ".gitignore", ".env*\nconfig/*.local\ncache/\n");
        yield* writeTextFile(cwd, ".worktreeinclude", ".env*\nconfig/*.local\n");
        yield* git(cwd, ["add", "-A"]);
        yield* git(cwd, ["commit", "-m", "ignore and include"]);
        yield* writeTextFile(cwd, ".env", "SECRET=1\n");
        yield* writeTextFile(cwd, "config/db.local", "port=5\n");
        yield* writeTextFile(cwd, "cache/blob", "not named, stays behind\n");
        yield* writeTextFile(cwd, "scratch.txt", "untracked, not named\n");
        const worktreePath = pathService.join(yield* makeTmpDir("git-worktrees-"), "seeded");

        yield* driver.createWorktree({
          cwd,
          path: worktreePath,
          refName: initialBranch,
          newRefName: "feature/seeded",
        });

        assert.equal(
          yield* fileSystem.readFileString(pathService.join(worktreePath, ".env")),
          "SECRET=1\n",
        );
        assert.equal(
          yield* fileSystem.readFileString(pathService.join(worktreePath, "config/db.local")),
          "port=5\n",
        );
        assert.equal(yield* fileSystem.exists(pathService.join(worktreePath, "cache/blob")), false);
        assert.equal(
          yield* fileSystem.exists(pathService.join(worktreePath, "scratch.txt")),
          false,
        );
        // The copies are the parent's gitignored files, so the worktree stays clean.
        assert.equal(yield* git(worktreePath, ["status", "--porcelain"]), "");
      }),
    );

    it.effect("seeds .env files by default when the repo has no .worktreeinclude (#270 A)", () =>
      Effect.gen(function* () {
        const cwd = yield* makeTmpDir();
        const { initialBranch } = yield* initRepoWithCommit(cwd);
        const pathService = yield* Path.Path;
        const fileSystem = yield* FileSystem.FileSystem;
        const driver = yield* GitVcsDriver.GitVcsDriver;
        yield* writeTextFile(cwd, ".gitignore", ".env*\n");
        yield* git(cwd, ["add", "-A"]);
        yield* git(cwd, ["commit", "-m", "ignore env"]);
        yield* writeTextFile(cwd, ".env.local", "KEY=v\n");
        yield* writeTextFile(cwd, "scratch.txt", "untracked\n");
        const worktreePath = pathService.join(yield* makeTmpDir("git-worktrees-"), "default-seed");

        yield* driver.createWorktree({
          cwd,
          path: worktreePath,
          refName: initialBranch,
          newRefName: "feature/default-seed",
        });

        assert.equal(
          yield* fileSystem.readFileString(pathService.join(worktreePath, ".env.local")),
          "KEY=v\n",
        );
        assert.equal(
          yield* fileSystem.exists(pathService.join(worktreePath, "scratch.txt")),
          false,
        );
      }),
    );
  });
});
