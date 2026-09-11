# Activity analytics — where the effort goes (research, 2026-09-04)

User: "analyze usages (now with claude, codex, grok build, etc. later) to
see things like token/effort/time for: code/pr review, writing tests,
explanations, plan/design, computer/browser/simulator uses … per models
maybe." Tracked as a GitHub issue; this note is the research behind it.

## What is observable today (Claude Code transcripts)

Probe over the 40 newest transcripts on this Mac (~91k assistant
entries). Every signal below is already in `~/.claude/projects/*/*.jsonl`
and the Stats scanner (`StatsScanner.ingest`) already walks every entry.

| signal | where | what it tells |
|---|---|---|
| `message.model` on every assistant entry | `claude-fable-5` 47k, `claude-opus-5` 27k, `claude-fable-5-1` 17k, `claude-opus-4-7/4-8` ~450 | per-model split of tokens/usd/turns for free |
| `effort` (entry key) | user entries carry the session's effort setting | effort dimension the user asked for, exactly |
| `advisorModel`, `permissionMode`, `entrypoint`, `mode` | entry keys | advisor pairing, bypass vs ask, CLI vs SDK vs remote |
| `Skill` tool_use `input.skill` | `code-review` 97, `pr-review-toolkit:review-pr` 14, `pr-review` 13, `superpowers:brainstorming` 10, `superpowers:writing-plans` 8, `subagent-driven-development` 5, `systematic-debugging` 2, `playwright-cli` 2 | the strongest activity label: a review/plan/debug/browser stretch starts here |
| `Agent` tool_use `input.subagent_type` | `coder` 268, `general-purpose` 205, `pr-test-analyzer` 174, `silent-failure-hunter` 162, `code-reviewer` 77, `Explore` 36 | delegated work by kind; the subagent transcript (`<sid>/subagents/agent-*.jsonl`) carries its own tokens/model |
| tool names | `Bash` 36k, `Edit` 4.7k, `Read` 2.8k, `Write` 2.5k, `WebSearch` 78, `WebFetch` 41, `mcp__claude-in-chrome__*`, `mcp__*` | browser/computer use = the `claude-in-chrome` family + `computer`; simulator = `xcrun simctl`/`xcodebuild -destination 'platform=iOS Simulator'` in Bash |
| `Edit`/`Write` file paths | `Tests/…`, `*Tests.swift`, `*.test.ts`, `__tests__/` | "writing tests" = edits whose path matches the test convention of the repo |
| `ExitPlanMode`/`EnterPlanMode`, `AskUserQuestion`, `Artifact` | tool_use | plan/design stretches; artifacts published |
| `ReportFindings`, `prNumber`/`prUrl` entry keys, `gh pr review`/`gh pr diff` in Bash | tool_use + keys | PR review stretches, tied to the PR |
| slash commands | `<command-name>/goal`, `/model`, `/effort`, `/clear` | model/effort changes mid-session — boundaries for the per-model split |
| assistant text with no tool_use, following a human question | existing "turn end" detection | "explanations": turns that end in prose only, no edits, no commands |
| `timestamp` per entry | already used for sessionSeconds/waiting | wall time per stretch |

## Classifier: stretches, not turns

A turn rarely is one activity; a session is many. Proposal: split each
transcript into **stretches** — a run of assistant entries between two
human/phone messages — and label each stretch by the strongest signal
in it, first match wins:

1. `Skill` name or `Agent` subagent_type in a known map → that label
   (`code-review`, `pr-review*`, `*-reviewer`, `silent-failure-hunter`,
   `pr-test-analyzer` → **review**; `brainstorming`, `writing-plans`,
   `EnterPlanMode` → **plan/design**; `systematic-debugging` → **debug**;
   `playwright-cli`, `mcp__claude-in-chrome__*`, `computer` → **browser**;
   simulator/device commands in Bash → **simulator/device**).
2. Every `Edit`/`Write` path matches the repo's test convention →
   **tests**; a mix → **code** (with a `testShare` ratio).
3. No edits, no Bash writes, prose end → **explanation**.
4. Else → **code**.

Per stretch: model (from the entries; a `/model` switch splits the
stretch), effort, input/output/cache tokens, usd (static table), wall
seconds, tool calls, human messages that opened it. Fold into
`Stats.Day` as `activities: [label: ActivityTally {stretches, seconds,
inputTokens, outputTokens, usd}]` and `byModel: [model: ActivityTally]`
— both additive, so the existing day/week/month/year folding and the
tile catalogue apply unchanged.

Accuracy note: labels are heuristics; show them as "where the effort
went (heuristic)" and keep an **Other** bucket honest. Tunable map in
Core with tests per rule; no ML.

## Other engines (later)

- **Codex CLI** — `~/.codex/sessions/**/*.jsonl` (8 files here).
  Events: `session_meta` (cwd, model_provider, cli_version),
  `turn_context` (model, effort), `response_item` (`message`,
  `reasoning`, `function_call`/`custom_tool_call` + outputs),
  `event_msg` (`token_count` with `total_token_usage`, `user_message`,
  `agent_message`, `task_started/complete`). Model `gpt-5.6-sol` seen.
  Same stretch classifier over function-call names + file paths; tokens
  from `token_count`, price table per model.
- **Gemini CLI** — `~/.gemini/` exists; transcript format to confirm.
- **Grok Build / Cursor / OpenCode** — nothing on disk here yet; add a
  `TranscriptSource` per engine (path glob + entry adapter → the same
  stretch model). The scanner's per-file cache, chunking and subagent
  handling are source-agnostic already.

## More insights worth adding (the user asked)

- **$ and minutes per activity, per model** — the headline: "reviews
  cost $X on Opus vs $Y on Sonnet this week".
- **Review yield**: findings reported (`ReportFindings` count) per review
  $; fix commits that followed a review within N minutes.
- **Test ROI**: test edits per code edit; test-file share of lines.
- **Explanation share**: how much of the spend produces no diff (prose
  only) — a proxy for "thinking partner" vs "coder" use.
- **Rework**: same file edited in ≥3 stretches in a day; reverts.
- **Delegation depth**: % of tokens spent in subagents, by subagent type;
  orchestrator vs worker model mix.
- **Effort setting vs outcome**: tokens per stretch at each `effort`;
  waiting time per effort.
- **Browser/simulator minutes**: wall time inside those stretches; retries.
- **Model switches**: `/model` events per day; usd before/after.
- **Context hygiene**: compactions per session, tokens per compaction
  cycle, cache-read share (cache hit ratio per model).
- **Interrupts**: `[Request interrupted` per stretch = user pulled the
  brake; correlates with wasted tokens.
- **Time of day per activity**: reviews in the morning, plans at night?
  (the heatmap, split by label).

## Cost

Core: stretch splitter + label map + two `Stats.Day` fields + tests
(~1–2 days). Surfaces: an "Activities" group in the catalogue (Mac,
phone, verb for free) + a per-model table on the Mac (~1 day). Codex
source adapter (~1 day). One cache version bump (full rescan, ~5 min).
