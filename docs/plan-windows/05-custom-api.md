# 05 — Custom API endpoints: proxy-independence, verified

Claim: the Windows remote path works unchanged whether `claude.exe` talks
to Anthropic directly or to a local swap proxy through `ANTHROPIC_BASE_URL`.

## What the daemon touches

| surface | read/write | proxy involvement |
|---|---|---|
| `C:\Users\BM\.claude\sessions\<pid>.json` | read | none — written by `claude.exe` regardless of API endpoint |
| `C:\Users\BM\.claude\sessions\<pid>.<hash>.key` | read | none |
| `C:\Users\BM\.claude\projects\<slug>\<sessionId>.jsonl` | read | none — the transcript is written locally before/after each API call, whatever the base URL |
| `\\.\pipe\LOCAL\cc-msg-<hex>` | write | none — CC's peer inbox is local IPC, independent of `--remote-control` and of the API endpoint |
| `C:\Users\BM\.claude\settings.json` | **not read** | the daemon never needs `env.ANTHROPIC_BASE_URL`; it is listed here only to state that it is untouched |
| HTTP 47824 | serve | the phone talks to the daemon, never to the proxy or to Anthropic |

Verified on this box (2026-09-04): `settings.json` `env` carries
`ANTHROPIC_BASE_URL` = `http://<host>/v1`, `ANTHROPIC_AUTH_TOKEN`, model
overrides (`ANTHROPIC_DEFAULT_OPUS/FABLE/SONNET/HAIKU_MODEL`) and
`CLAUDE_CODE_*` knobs; the 7 live sessions run under that config and their
records, key files, transcripts and pipes are all present and normal
(sessions list, slug resolution, pipe `WaitNamedPipeW` all succeeded).
`claude --remote-control` is not involved anywhere in this design, so its
custom-base-URL lockout is irrelevant.

Transcript content under a proxy: entries still carry `cwd`, `version`
(2.1.260), `gitBranch`, `message.content` blocks, `uuid`, `timestamp`; the
proxy only changes `message.model` strings (e.g. an alias). `SessionsScreen.shortModel`
strips `claude-` and a trailing `-20…` date; an aliased model id renders
as-is. Nothing else in `SessionProgress`/`SessionFeed` keys on the model
name.

## What must NOT be built

- No engine on Windows in this plan: cswap is macOS-only; the proxy's own
  account policy stays in the proxy (CLAUDE.md: account policy lives in the
  engines). The Windows fleet reports `accounts: []`.
- The daemon never reads `~/.claude-swap-backup/*` or any proxy state.
- A future Windows engine (CLIProxyAPI, 9router — both already have
  `AccountEngine` implementations in `Sources/InfinitusCore/Engines/` that
  compile on Windows) would plug into `Snapshot.swift` as another
  `EngineFleet`; gate UI on `capabilities`, never on host OS.

## Acceptance (W12)

1. With `ANTHROPIC_BASE_URL` set to the proxy (current state): start a
   session in Windows Terminal, `infinitus-win sessions` lists it, the
   phone feed shows its turns, a phone message arrives in the terminal.
2. Temporarily unset `ANTHROPIC_BASE_URL` (a session started with
   `claude` in a shell where `env` overrides are cleared via
   `CLAUDE_CONFIG_DIR` pointing at a copy of `.claude` without the `env`
   block): repeat step 1 with `--claude-dir` pointed at that copy. Same
   results. Restore.
3. Point the proxy at an unreachable upstream so the session's API call
   fails: the feed shows the API error entry (`system`/`api_error` →
   not a limit stop, `Transcript.isLimitStop` false); no resume nudge is
   attempted (`06-nudge-resume.md`).
