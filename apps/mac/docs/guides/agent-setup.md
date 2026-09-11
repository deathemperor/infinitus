# Setting up Infinitus — the agent guide

For a coding agent (Claude Code, Codex, an SSH'd assistant) asked to
"set up Infinitus" on a Mac. Every step is idempotent; run them in
order and skip the ones already done. The in-app equivalent is the
first-run card's **Copy for an AI agent** button, which fills in what
it already found on the machine.

**Two rules.** A human signs into every account — you never type or
paste credentials, and you never read `~/.claude-swap-backup/`. Before
anything destructive (`cswap remove`, `cswap purge`, `infinitusctl
remove`) ask.

## 0. What you are installing

- **Infinitus.app** — the menu bar app: one row per account with 5h / 7d
  gauges, the active account's reset countdown in the bar, the
  auto-switch cockpit, a phone mirror.
- **claude-swap (`cswap`)** — the engine. It holds the accounts, rotates
  Claude Code between them, and runs the auto-switcher. Infinitus only
  ever talks to it as `cswap … --json`.

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

Either click **Install engine** in the popup (it bootstraps `uv` if
needed and relaunches), or from a shell:

```sh
command -v uv >/dev/null || brew install uv    # or: curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install claude-swap
cswap --version
```

`uv` puts `cswap` in `~/.local/bin`; Infinitus looks there, in
`/opt/homebrew/bin` and `/usr/local/bin`. Relaunch the app after the
first install so it re-detects the engine (`infinitusctl status` →
`engines.cswap.registered: true`).

## 3. Register the accounts

`cswap add` adopts whatever account Claude Code is currently signed
into. So, for each account:

1. Tell the human: run `claude`, then `/login`, and finish the browser
   sign-in as account N. (For a second account: `/logout` first.)
2. `cswap add` — registers it. `cswap alias <n> <short-name>` is
   optional but the menu bar caps names at 10 characters.
3. `cswap list --json` — confirm the row appears with `usage`.

Alternatives that skip Claude Code's own login: `infinitusctl add
cswap/claude` opens an in-app sign-in window the human completes
(`infinitusctl wait-add` blocks until it ends); `cswap add-token -`
reads a setup token / API key from stdin.

## 4. Auto-switching

Infinitus runs `cswap auto` itself while it is open (Settings → Engines
shows the supervisor); nothing to start. The knobs are the engine's
(never re-implement them app-side):

```sh
cswap config list                                  # every setting with its default
cswap config set autoswitch.threshold 95           # switch when the binding window hits 95 %
cswap config set autoswitch.preferred you@x.io     # land on this account first (the ★ in the app)
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
infinitusctl status | jq '.badge, .engines.cswap'   # "running", registered: true
cswap list --json | jq '.accounts | length'          # ≥ 1
infinitusctl fleets | jq '.[0].accounts[] | {number, active, pct: .usage.fiveHour.pct}'
```

The popup shows one row per account with gauges; the menu bar shows
the active account's name, percentages and reset.

## Don'ts

- No secrets on a command line, in a file you write, or in a log.
- Don't edit `~/.claude/settings.json` or anything in
  `~/.claude-swap-backup/`; the human and the engine own those.
- Don't set an app-side "policy" (ordering, thresholds) — those are
  `cswap config` keys, and Infinitus reads them.
