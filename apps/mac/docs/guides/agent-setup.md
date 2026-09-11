# Setting up Infinitus — the agent guide

For a coding agent (Claude Code, Codex, an SSH'd assistant) asked to
"set up Infinitus" on a Mac. Every step is idempotent; run them in
order and skip the ones already done. The in-app equivalent is the
first-run card's **Copy for an AI agent** button, which fills in what
it already found on the machine.

**Two rules.** A human signs into every account — you never type or
paste credentials, and you never read `~/.swapd/` (the engine's own
store). Before anything destructive (`swapd remove`, `swapd unclaimed
--purge`, `infinitusctl remove`) ask.

## 0. What you are installing

- **Infinitus.app** — the menu bar app: one row per account with 5h / 7d
  gauges, the active account's reset countdown in the bar, the
  auto-switch cockpit, a phone mirror.
- **[swapd](https://github.com/deathemperor/swapd)** — the engine. It
  holds the accounts, rotates Claude Code between them, and runs the
  auto-switcher. Infinitus only ever talks to it as `swapd … --json`.

Most people run **one or two accounts**. That is the mainline setup;
everything below works with a single account (you get the gauges, the
reset countdown, the forecast) and adds rotation from the second one.

## 1. Install the app

```sh
brew install --cask --no-quarantine deathemperor/tap/infinitus
open -a Infinitus
```

`--no-quarantine` because builds are ad-hoc signed, not notarized.
Without Homebrew: unzip `Infinitus-<version>.zip` from
<https://github.com/deathemperor/infinitus/releases> into `/Applications`.
Nightly track: `deathemperor/tap/infinitus@nightly`.

Put the control CLI on PATH (optional, used by the rest of this guide):

```sh
ln -sf /Applications/Infinitus.app/Contents/MacOS/infinitusctl /usr/local/bin/infinitusctl
infinitusctl status        # exit 3 = app not running
```

## 2. Install the engine

The first-run card shows the same line; from a shell (needs a Rust
toolchain — `brew install rust` — until a release archive or formula
exists):

```sh
cargo install --git https://github.com/deathemperor/swapd swapd
swapd version
swapd doctor          # stores, locks, the Claude CLI it found
```

`cargo` puts `swapd` in `~/.cargo/bin`; Infinitus looks there, in
`~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`
(`INFINITUS_SWAPD_CLI=<path>` overrides). Relaunch the app after the
first install so it re-detects the engine (`infinitusctl status` →
`engines.swapd.registered: true`).

## 3. Register the accounts

`swapd add` adopts whatever account Claude Code is currently signed
into. So, for each account:

1. Tell the human: run `claude`, then `/login`, and finish the browser
   sign-in as account N. (For a second account: `/logout` first.)
2. `swapd add` — registers it into the next slot (`--alias <short-name>`
   is optional but the menu bar caps names at 10 characters).
3. `swapd list --json` — confirm the row appears under
   `providers[].accounts` with `windows`.

Alternatives that skip Claude Code's own login: `infinitusctl add
swapd/claude` opens an in-app sign-in window the human completes
(`infinitusctl wait-add` blocks until it ends); `swapd add-token -`
reads a setup token / API key from stdin.

## 4. Auto-switching

Infinitus runs `swapd auto` itself while it is open (Settings → Engines
shows the supervisor); nothing to start. The knobs are the engine's,
one set per provider (never re-implement them app-side):

```sh
swapd config list                              # every setting with its default and help
swapd config set claude.threshold 95           # switch when the binding 5h/7d window hits 95 %
swapd config set claude.strategy best          # how the target is picked (best, consume-first, …)
swapd prefer 2 on                              # land on slot 2 first (the ★ in the app)
swapd hold 3                                   # take slot 3 out of the rotation; unhold puts it back
```

With **one account** there is nothing to rotate to; auto-switch stays
idle and the app is a usage meter with a forecast. That is fine.

## 5. Check the menu bar

The bar shows `name · 5h·7d% · ↺reset` for the active account — e.g.
`loc · 75·40% · ↺2h14m`: 75 % of the 5-hour window used, 40 % of the
week, the fuller window resets in 2 h 14 m. Settings → Display →
*Reset time in title* switches the countdown to a clock time or off;
*Menu bar counts remaining, not used* flips the percentages. Keep the
title short — macOS silently evicts status items that stop fitting.

## 6. Optional extras

- **Phone mirror** (iPhone app): Settings → Devices has its own *Copy
  for an AI agent* brief; pairing is a token the human scans or pastes,
  the Mac serves the phone directly (Wi-Fi, Tailscale, or a Cloudflare
  quick tunnel). Live Activities need the phone app installed once.
- **CLIProxyAPI / 9Router** as further engines: `docs/guides/cliproxyapi-setup.md`;
  the management key/password goes in through Settings → Engines (the
  human pastes it) or `infinitusctl proxy-key < file` — never argv.
- **Driving the running app**: `docs/guides/infinitusctl-agent.md`
  (`infinitusctl manifest` first).
- **Engineering stats**: `infinitusctl stats [--period week]` returns
  the same commits/lines/PRs/messages/sessions/cost numbers as
  Settings → Stats, as JSON.

## 7. Verify

```sh
infinitusctl status | jq '.badge, .engines.swapd'   # "running", registered: true
swapd list --json | jq '.providers[] | select(.provider == "claude") | .accounts | length'   # ≥ 1
infinitusctl fleets | jq '.[0].accounts[] | {number, active, pct: .usage.fiveHour.pct}'
```

The popup shows one row per account with gauges; the menu bar shows
the active account's name, percentages and reset.

## Don'ts

- No secrets on a command line, in a file you write, or in a log.
- Don't edit `~/.claude/settings.json` or anything in `~/.swapd/`; the
  human and the engine own those.
- Don't set an app-side "policy" (ordering, thresholds) — those are
  `swapd config` keys, `prefer`, `hold` and `reorder`, and Infinitus
  reads them.
