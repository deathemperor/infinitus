import { it, expect } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as ChildProcessSpawner from "effect/unstable/process/ChildProcessSpawner";
import { ProcessRunner } from "../processRunner.ts";
import { makeStatsRepositoryScanner } from "./statsRepositories.ts";

it.effect(
  "shares a worktree scan, reuses unchanged history, and retains counts after a failed refresh",
  () =>
    Effect.gen(function* () {
      let failLog = false,
        head = "first";
      const invocations: string[] = [];
      const runner = ProcessRunner.of({
        run: (input) =>
          Effect.sync(() => {
            const command = input.command + " " + input.args.join(" ");
            invocations.push(command);
            const log = input.args[0] === "log";
            const stdout =
              input.command === "gh"
                ? '[{"url":"https://github.com/me/repo/pull/1","createdAt":"2026-09-21T00:00:00Z","mergedAt":"2026-09-22T00:00:00Z"}]'
                : input.args.includes("--git-common-dir")
                  ? "/fake/shared.git"
                  : input.args[0] === "config"
                    ? "me@example.com"
                    : input.args[0] === "remote"
                      ? "git@github.com:me/repo.git"
                      : log
                        ? "\x1eabc\x1f2026-09-22T10:00:00Z\x1fme@example.com\x1ffeature\x1f\n10\t2\tfile.ts\n"
                        : head;
            return {
              stdout,
              stderr: "",
              code: ChildProcessSpawner.ExitCode(log && failLog ? 1 : 0),
              timedOut: false,
              stdoutTruncated: false,
              stderrTruncated: false,
              stdoutInvalidUtf8: false,
              stderrInvalidUtf8: false,
            };
          }),
      });
      const scan = makeStatsRepositoryScanner(runner);
      const first = yield* scan(["/fake/worktree-a", "/fake/worktree-b"], "2025-01-01", "host");
      expect(first).toHaveLength(1);
      expect(first[0]?.commits[0]?.added).toBe(10);
      expect(first[0]?.pullRequests).toHaveLength(1);
      yield* scan(["/fake/worktree-a"], "2025-01-01", "host");
      expect(invocations.filter((c) => c.startsWith("git log"))).toHaveLength(1);
      expect(invocations.filter((c) => c.startsWith("gh "))).toHaveLength(1);
      head = "second";
      failLog = true;
      const partial = yield* scan(["/fake/worktree-a"], "2025-01-01", "host");
      expect(partial[0]?.complete).toBe(false);
      expect(partial[0]?.commits).toEqual(first[0]?.commits);
    }),
);
