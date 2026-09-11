# Stats — engineering metrics per day / week / month / year

User 2026-09-04: "tracking: PRs, commits, line of code, messages (human
messages, messages sent from ios now use agent messages so don't mistake
them), active agents (sessions). these are per days/weeks/months/year.
brainstorm more engineering metrics." Decisions taken in the same
conversation: everything in v1 (five + limits, autonomy + friction, cost
per outcome, rhythm); Mac Stats tab + phone Stats screen + `infinitusctl
stats` + a wall strip; PRs from `gh` when available, merge commits
otherwise; backfill from what is on disk; keyboard + phone messages are
both "human"; counts land on the local calendar day the entry was
written; git author = the union of `user.email` across the repos seen.

## Non-negotiables kept
- Engine untouched; only Claude Code's own files (`~/.claude/projects/
  */*.jsonl`), git/gh on the sessions' cwds, and the app's own event log.
- Usage-cost figures are estimates (the existing static price table).
- No network except `gh` (already authed by the user; skipped silently
  when missing or offline).

## Sources → facts

All facts are per local calendar day. `Stats.Day` is a `Codable` value
with `static func +` so days fold into any period.

### Transcripts (`StatsScanner`, InfinitusCore/Stats.swift)
Modeled on `TokenRateScanner`: per-file `{size, offset, days:[String:
Day]}` cache; re-parse only appended bytes, from the byte watermark;
reset on shrink; partial last line waits. No lookback cap (the
backfill is the first scan); files older than 400 days are skipped.

| fact | from |
|---|---|
| `humanMessages` | `type=user` whose `presentableUserText` does not start with `<` (keyboard), plus `attachment.queued_command` prompts |
| `phoneMessages` | cross-session wrapper with `from-name="Infinitus"` whose body does not start with `[Infinitus]` |
| `agentMessages` | any other cross-session wrapper |
| `nudges` | `from-name="Infinitus"` body starting `[Infinitus]` |
| `turns` | assistant text blocks that are turn ends (`isTurnEnd`) |
| `toolCalls[name]`, `toolErrors` | `tool_use` blocks; `tool_result` with `is_error` |
| `permissionPrompts`, `questions` | same detection as `SessionFeed.parse` |
| `waitingSeconds` | gap from a prompt/question entry to the next human/phone entry (capped at 8 h per gap) |
| `outputTokens`, `inputTokens`, `usd` | `message.usage` × `StaticPriceTable`, deduped on `message.id` |
| `sessions` | distinct transcript files with ≥1 entry that day; `sessionSeconds` = last − first entry per file per day |
| `subagents` | `Agent` tool_use blocks |
| `compactions` | `isCompactSummary` / summary entries |
| `retries` | assistant entries with `isApiErrorMessage` |
| `hours[24×7]` | entries per hour × weekday (rhythm heatmap) |

### Git (`RepoStats`, Infinitus/RepoStatsScanner.swift)
Repos = distinct cwds of session records (live + transcript `cwd`
fields), deduped by `git rev-parse --show-toplevel`. Per repo, cached
by HEAD sha: `git log --all --author=<e1> --author=<e2> … --since=<oldest
day needed> --format='%H%x1f%ad%x1f%an%x1f%(trailers:key=Co-authored-by)'
--date=iso-strict --numstat`. Emails = union of `git config user.email`
over the repos; a repo with none contributes nothing and is listed in
the tile's footnote. Facts: `commits`, `linesAdded`, `linesRemoved`,
`filesTouched`, `coAuthoredByClaude` (trailer contains "Claude"),
`reverts` (subject starts "Revert"), `repos` (distinct). Subprocesses
run through the `CswapCLI.run` pattern (Process on a global queue).

### GitHub (`gh`)
Per repo with a GitHub remote, at most hourly: `gh pr list --author @me
--state all --limit 200 --json number,createdAt,mergedAt,closedAt`.
Facts: `prsOpened`, `prsMerged` (by mergedAt day), `mergeHours` (sum +
count → mean). Without `gh` or offline: `prsMerged` = merge commits
(`--merges`) and squash merges are invisible; the tile says "from git".

### Events (`EventStore`, Infinitus/EventStore.swift)
Append-only `Infinitus/events.jsonl` (`{at, icon, kind, text}`),
written by the one place that appends to `eventLog`; `eventLog` becomes
the in-memory tail. Kinds: `switch`, `limit`, `revival`, `nudge`,
`ignite`, `resume`, `pairing`, `other`. Facts: `switches`, `limitStops`,
`revivals`, `nudges`, `ignites`, `minutesLostToLimits` (span between an
all-dead event and the next revival). Retention 400 days, pruned on
launch. History starts at ship time — the tile says "since <date>" while
the period predates it.

### Derived (`Stats.Summary`, pure)
messages per commit, tool calls per human message, $ per commit, $ per
PR, tokens per line landed, human share of messages, waiting minutes
per day, longest unattended run (largest tool-call count between two
human messages), session length buckets (<15m / 15–60m / 1–4h / >4h),
streak (consecutive days with ≥1 commit or ≥1 human message), and the
24×7 heatmap. Division by zero → nil (tile shows "—").

## Store
`~/Library/Application Support/Infinitus/stats/`:
`transcripts.json` (scanner cache), `repos/<sha256(toplevel)>.json`,
`gh/<same>.json`, and `events.jsonl` one level up. All atomic writes.
Dev instances (`isDevInstance`) use the same paths — the cache is per
transcript path, so a demo engine changes nothing.

## Aggregation
`Stats.fold(days:[Day], period:, now:) -> Summary` with periods `day`
(today), `week` (Mon–Sun, current), `month`, `year`, each carrying the
per-day series for sparklines and the previous period's total for the
delta. Local `Calendar.current`.

## Surfaces
- **Mac — Settings › Stats** (after Utilization; `chart.bar`, tint
  indigo). Segmented Day / Week / Month / Year; groups Throughput,
  Autonomy, Friction, Limits, Cost, Rhythm; each tile = value, delta vs
  previous period, sparkline of the period's days. Rhythm shows the
  heatmap and session-length bars. Footnotes: repos counted / skipped,
  `gh` used or "from git", "limits since <date>". Refresh with the
  Utilization cadence (`loadIfNeeded` on open, then every 5 min), all IO
  in `Task.detached(priority: .utility)`. `StatsModel` is constructed
  in `settingsTabs` like `UtilizationModel`; AppModel feeds it the event
  store and the session cwds.
- **Phone** — `MirrorSnapshot.stats: Stats.Bundle?` (additive optional,
  the four periods' summaries without the heatmap series, ≤ 8 KB) written
  by the exporter every 5 min; a Stats screen pushed from the Fleet
  tab's toolbar, same groups as tiles. Parity: everything the Mac shows
  except the heatmap.
- **Wall** — one strip: today's commits · PRs · human messages ·
  sessions · $ and the week's totals under them.
- **`infinitusctl stats [--period day|week|month|year]`** → the
  `Summary` JSON for that period (default week); `manifest` documents
  it; `tools/e2e.sh` asserts `{period, commits, humanMessages,
  sessions}` are present against the demo engine (numbers may be 0).
- **Linux tray** — `parity pending` (no transcript scan there yet).

## Tagging fix
`AwsLogin` "login completed" nudge gets the `[Infinitus]` prefix so
phone-vs-nudge is exact; the scanner's rule holds for history because
the other two nudges always had it.

## Performance
First scan of a large history runs once at utility QoS off the main
thread and reports progress in the tab ("scanning 412 transcripts…").
Steady state: one `stat` per transcript file per refresh (same as the
run-rate scanner), git only when HEAD moved, gh hourly. Idle CPU gate
unchanged (`tools/e2e.sh` perf check).

## Testing
Pure: `StatsTests` — parse a fixture transcript (keyboard, phone,
agent, nudge, queued prompt, permission → answer gap, tool error,
compaction) into a `Day`; fold days into week/month with delta; derived
ratios incl. nil on zero; git log output parsing incl. co-author
trailer and numstat binary lines (`-`); gh JSON parsing; event kinds →
facts incl. minutes lost. App: e2e `stats` verb shape.

## Out of scope
Per-account cost split (needs the engine's per-request attribution);
edit accept/reject rates (not observable); Linux transcript scan.
