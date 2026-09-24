import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import type { StatsCommit, StatsRepository } from "@infinitus/contracts";
import { readDirectoryVolumeId } from "../usage/usageTranscriptReader.ts";
import type { ProcessRunner } from "../processRunner.ts";

export const STATS_LOG_FORMAT =
  "%x1e%H%x1f%aI%x1f%ae%x1f%s%x1f%(trailers:key=Co-authored-by,valueonly,separator=%x20)";
export function parseStatsLog(raw: string): StatsCommit[] {
  return raw.split("\x1e").flatMap((record) => {
    const [header, ...lines] = record.trim().split("\n");
    const [id, date, , subject, trailers] = (header ?? "").split("\x1f");
    const at = Date.parse(date ?? "");
    if (!id || !Number.isFinite(at)) return [];
    let added = 0,
      removed = 0,
      files = 0;
    for (const line of lines) {
      const parts = line.split("\t");
      if (parts.length < 3) continue;
      files++;
      added += Number(parts[0]) || 0;
      removed += Number(parts[1]) || 0;
    }
    return [
      {
        id,
        at,
        added,
        removed,
        files,
        coAuthored: /claude/i.test(trailers ?? ""),
        revert: subject?.startsWith("Revert ") ?? false,
      },
    ];
  });
}
export function statsRepositoryIdentity(remote: string, fallback: string) {
  const value = remote
    .trim()
    .replace(/^git@([^:]+):/, "https://$1/")
    .replace(/^ssh:\/\/git@/, "https://")
    .replace(/\.git\/?$/, "")
    .replace(/\/$/, "");
  try {
    const url = new URL(value);
    return url.host.toLowerCase() + url.pathname;
  } catch {
    return fallback;
  }
}
const PullRequests = Schema.Array(
  Schema.Struct({
    url: Schema.String,
    createdAt: Schema.String,
    mergedAt: Schema.NullOr(Schema.String),
  }),
);
const decodePrs = Schema.decodeUnknownOption(Schema.fromJsonString(PullRequests));

/** Bounded git history; worktrees share one common-dir scan, gh refreshes hourly. */
export function makeStatsRepositoryScanner(runner: ProcessRunner["Service"]) {
  const cache = new Map<
    string,
    { head: string; since: string; email: string; readAt: number; repository: StatsRepository }
  >();
  const run = Effect.fn("Stats.repositories.command")(function* (
    cwd: string,
    command: string,
    args: readonly string[],
  ) {
    return yield* runner
      .run({ command, args, cwd, timeout: "20 seconds", maxOutputBytes: 8 * 1024 * 1024 })
      .pipe(
        Effect.map((result) =>
          result.code === 0 && !result.stdoutTruncated ? result.stdout.trim() : null,
        ),
        Effect.catch(() => Effect.succeed(null)),
      );
  });
  return Effect.fn("Stats.repositories.scan")(function* (
    cwds: readonly string[],
    since: string,
    host: string,
  ) {
    const now = yield* Clock.currentTimeMillis;
    const roots = new Map<string, { cwd: string; email: string }>();
    for (const cwd of new Set(cwds)) {
      const common = yield* run(cwd, "git", [
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
      ]);
      if (!common || roots.has(common)) continue;
      const email = yield* run(cwd, "git", ["config", "user.email"]);
      roots.set(common, { cwd, email: email ?? "" });
    }
    return yield* Effect.forEach(
      [...roots],
      Effect.fn("Stats.repositories.one")(function* ([common, { cwd, email }]) {
        const head = yield* run(cwd, "git", ["rev-parse", "HEAD"]);
        const old = cache.get(common);
        if (
          old &&
          old.head === head &&
          old.email === email &&
          old.since === since &&
          now - old.readAt < 3600000
        ) {
          return old.repository;
        }
        const remote = yield* run(cwd, "git", ["remote", "get-url", "origin"]);
        const volume = yield* Effect.promise(() => readDirectoryVolumeId(common));
        const id = statsRepositoryIdentity(remote ?? "", `${host}:${common}:${volume}`);
        const log = email
          ? yield* run(cwd, "git", [
              "log",
              "HEAD",
              "-F",
              "--no-merges",
              "--numstat",
              "--max-count=20001",
              `--format=${STATS_LOG_FORMAT}`,
              `--since=${since}T00:00:00Z`,
              `--author=${email}`,
            ])
          : null;
        const parsed = log === null ? (old?.repository.commits ?? []) : parseStatsLog(log);
        const rawPrs = remote
          ? yield* run(cwd, "gh", [
              "pr",
              "list",
              "--state",
              "all",
              "--author",
              "@me",
              "--limit",
              "1000",
              "--search",
              `updated:>=${since}`,
              "--json",
              "url,createdAt,mergedAt",
            ])
          : null;
        const decoded = rawPrs === null ? Option.none() : decodePrs(rawPrs);
        const pullRequests = Option.isSome(decoded)
          ? decoded.value.flatMap((pr) => {
              const openedAt = Date.parse(pr.createdAt),
                mergedAt = pr.mergedAt === null ? null : Date.parse(pr.mergedAt);
              return Number.isFinite(openedAt) && (mergedAt === null || Number.isFinite(mergedAt))
                ? [{ id: pr.url, openedAt, mergedAt }]
                : [];
            })
          : (old?.repository.pullRequests ?? []);
        const repository: StatsRepository = {
          id,
          commits: parsed.slice(0, 20000),
          pullRequests,
          complete: log !== null && parsed.length <= 20000,
          pullRequestsAvailable: Option.isSome(decoded) && decoded.value.length < 1000,
        };
        cache.set(common, { head: head ?? "", since, email, readAt: now, repository });
        return repository;
      }),
      { concurrency: 4 },
    );
  });
}
