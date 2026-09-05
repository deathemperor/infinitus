# Infinitus

**Every Claude account in one menu bar — swap before you stall.**

May your limits never bind.

[![Release](https://img.shields.io/github/v/release/deathemperor/infinitus)](https://github.com/deathemperor/infinitus/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![Homebrew](https://img.shields.io/badge/homebrew-deathemperor%2Ftap-orange)](https://github.com/deathemperor/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

![Infinitus demo — layouts, compact mode, pop-out, live theme switching](docs/demo.gif)

A native macOS menu bar app (Swift/SwiftUI) over the
[claude-swap](https://github.com/deathemperor/claude-swap) engine: live
usage gauges for a whole fleet of Claude accounts, auto-switch awareness,
and a one-click rotate — wrapped in themes from RPG to Wild West.

## Why

Claude usage windows run out at the worst moment. If you keep more than
one account, the juggling — which one has 5-hour headroom, which weekly
window is about to bind, which one just died — is exactly the kind of
state a menu bar should carry for you. Infinitus shows the whole fleet at
a glance and swaps before you stall.

## Install

### Homebrew

```sh
brew install --cask deathemperor/tap/infinitus
```

Nightly channel (built from `main` every day; reinstall to update —
or flip the track in-app under About → Update channel):

```sh
brew install --cask deathemperor/tap/infinitus@nightly
```

Releases are Developer ID signed and notarized since 0.4.3, so they
open like any other app. Nightly builds are ad-hoc signed: install
those with `--no-quarantine` (or right-click → Open once).

### GitHub releases

Grab `Infinitus-<version>.zip` from
[releases](https://github.com/deathemperor/infinitus/releases), unzip,
drop `Infinitus.app` into `/Applications`.

### Linux — engine CLI + Waybar module (Omarchy-ready)

The menu bar app is macOS-native (AppKit), but its Swift core ports:
`infinitus-tray` renders the same fleet — themes, sentinel notes,
one-click rotate — as a Waybar module for
[Omarchy](https://omarchy.org) and any Waybar desktop
(see [`packaging/omarchy/`](packaging/omarchy/README.md)).
The engine itself (fleet gauges, auto-switching, the `cswap` TUI)
runs anywhere Python 3.12 does:

```sh
brew install deathemperor/tap/claude-swap    # Homebrew on Linux (or macOS)
uv tool install claude-swap                  # or straight from PyPI
```

Arch users can build from [`packaging/aur/PKGBUILD`](packaging/aur/) —
`cswap` in a terminal is the same account switching, Omarchy-style.

> **Container-tested only.** The PyPI install (`python:3.12` image), the
> PKGBUILD (`archlinux` image, `makepkg -s`) and the static
> `infinitus-tray` binary (Arch Linux ARM image, themed Waybar JSON
> against a demo fleet) all run in containers — no real accounts or
> desktop session were involved. Reports from actual Linux desktops
> welcome.

### Windows — phone remote daemon (`infinitus-win`)

Windows runs Claude Code natively (Windows Terminal + `claude.exe`), but
Claude Code's built-in `--remote-control` is disabled under custom
`ANTHROPIC_BASE_URL` configs. `infinitus-win` provides a native Windows daemon
and CLI that bridges local Claude Code sessions, transcripts, and named pipes to
the [Infinitus mobile companion](ios/InfinitusMobile).

See [`windows/README.md`](windows/README.md) for toolchain setup (`winget install --id Swift.Toolchain -e`),
build instructions, firewall configuration, and CLI commands (`serve`, `sessions`,
`pair`, `snapshot`, `message`, `resume`).

### Requirements

- macOS 14+ (best on macOS 26 — the glass chrome uses it)
- the `cswap` CLI on PATH (`uv tool install claude-swap` /
  `pipx install claude-swap`) — the app's first-run card installs it
  for you

Setting it up with a coding agent? Hand it
[docs/guides/agent-setup.md](docs/guides/agent-setup.md) — install,
engine, accounts, auto-switch knobs, menu bar, verification — and
[docs/guides/infinitusctl-agent.md](docs/guides/infinitusctl-agent.md)
to drive the running app.

## Features

One line per feature; the site and the CHANGELOG carry the detail.

- **Menu bar usage** — the active account with its 5h and weekly percentages (used or remaining), the next reset, or glyph-only.
- **One account, one card** — a single account gets big gauges and full reset text; two or more get the grid.
- **Every account at a glance** — live 5-hour, weekly and per-model gauges, pace markers, reset countdowns, dead rows with the cause.
- **Auto-switch aware** — the next-candidate pick, a themed marker on the active account, switch history, a sweep on every switch.
- **Themes** — RPG, Movie, Hades, Metal Gear, Sci-Fi, Cyberpunk, Ocean and more, your own via `themes.json`, a community gallery; the phone follows.
- **Themed menu bar** — the loop in the theme's color with its icon, a glow on switch, death and revival, an ember breath while burning ahead of pace.
- **Glass popup** — real backdrop blur in every focus state with a transparency dial, and a launch intro.
- **Right-click menu** on the bar icon — themes, rotate, refresh, capture, pin, pop out, settings, restart, quit.
- **Sessions & status chips** — the live Claude Code session count with its busy/idle split, engine status, auto-mode.
- **Resume nudges** (opt-in) — sessions a limit stopped get a "continue" typed into their terminal or sent over the peer socket once an account works again.
- **Revival probes** — when a countdown ends the Mac asks the engine again at once, and "<account> is back" says so, flagged when Anthropic reset early.
- **Cost estimates** — 7-day per-account API-list-price estimates, never billing truth.
- **iCloud settings sync** and file export/import, never credentials.
- **Push notifications** — switch and limit events to Slack, Discord, Telegram or a webhook; secrets over stdin, shown masked.
- **Pop-out window, compact mode, three layouts, popup scaling** — the pop-out remembers its spot.
- **Sessions by name** — `/rename` names label the rows on the Mac and the phone, with branch, model, kind and output size.
- **Phone companion, four ways in** — Wi-Fi (Bonjour), Tailscale, your own Cloudflare tunnel or a free quick tunnel; one QR carries every route.
- **Session chat from the phone** — each transcript as a chat with markdown, tool chips and sub-agent cards; reply, attach photos and files, answer prompts.
- **Allow for this session** — the phone's permission card can allow a tool for the rest of the session; with the plugin, that prompt never comes back.
- **Start a session from the phone** — a repository, the engine, a first prompt; the Mac opens cmux or Terminal and the chat follows. Siri too.
- **Widgets in your theme** — home and lock-screen widgets show the active account's windows, what's waiting, and the revival countdown.
- **AWS sign-in from the phone** — an expired `aws login` shows up on both, the phone runs it with passkeys, and the session is told to continue.
- **Three engines** — cswap, CLIProxyAPI and 9Router as stacked fleets; policy stays in each engine, the app sets its knobs.
- **"At this pace"** — measured burn per window, when each runs out, a per-account forecast and a plain-words plan for the next reset.
- **Stats** — commits, lines, PRs, messages, sessions, tool calls, waiting time, switches, cost; effort per activity, model, engine and effort setting; tokens/min records.
- **Sessions, named and narrated** — unnamed sessions get a Haiku title that follows the work; the phone opens on what's waiting, with Continue.
- **A Claude Code plugin** — `infinitusctl plugin install`: hooks that reach the phone the moment a session needs you, an MCP server (`fleet_status`, `list_sessions`, `session_message`), `/infinitus:status` and `/infinitus:handoff`.
- **This Mac's name** — Settings › Devices names the Mac for the phone, widgets and crash reports; the default drops macOS's "(7)" suffix.
- **Capture the desktop into a session** — a region or window, a session, a note, delivered like a phone message.
- **Dictate in any language** — Vietnamese in, an editable English draft out, with the session's own terms taught to the recognizer.
- **All accounts limited, handled** — a floating countdown to the first account back and the sessions waiting to resume.
- **Share → Infinitus from any app** — images, files, a link or text into a session with a note; your sessions sit in the share sheet's suggestions.
- **Chat headers in three styles** — compact, a stat strip, or Game HUD with a ringed portrait and HP/MP-style bars in the theme's colors.
- **Live Activities that keep moving** — with an APNs key the lock-screen countdown and working card update with the app closed; the icon follows the theme.
- **Reset and swap alarms on the phone** — local notifications ten minutes before an exhausted account's reset and when a swap is near.
- **Crash reports, on-device** — both apps record their own crashes; any report can go into a session's chat for triage.
- **Randomize names** — every account gets a fresh name from the theme's pool.
- **Team (preview)** — `infinitusctl team` creates a team on any git remote and exchanges end-to-end encrypted files between members.
- **`infinitusctl`** — an agent-facing control CLI: status, fleets, sessions, send, switch, hold, rename, proxy, AWS logins, stats, perf; plus an agent-setup guide.

## Privacy

Everything stays on your machine (the phone talks straight to your Mac
over routes you enable; the only thing that ever touches infinitus.run
is a quick tunnel's URL, keyed by a hash of the pairing token — never
the token, never usage). The app talks to the engine through
`cswap … --json` subprocesses and never reads its files (resume nudges
read Claude Code's own session records and transcripts, nothing of the
engine's); usage-cost
figures are estimates, never billing truth; push-notification secrets
travel over stdin and render masked.

## Build from source

```sh
./make-app.sh && open Infinitus.app
```

`swift test` runs the InfinitusCore unit tests. `dev.sh` is a rebuild-on-save
loop (needs `entr`). `run-unbundled.sh` runs the executable outside the
bundle — a workaround for a login session whose menu bar stops adopting
new bundled apps (see the script header).

## Playground (development)

![Playground — the production popup on a demo fleet, every animation on demand](docs/playground.png)

A resizable window for developing the popup's UI and animations against a
fabricated fleet — one account per condition (healthy, mildly and hotly
ahead of pace, dead, fresh, behind pace, needs re-login, disabled,
near-reset) — so every state is always on screen at once.

Open it (debug builds): `defaults write <domain> debug_menu -bool true`,
then the wand button in the popup footer or Settings → Animations →
Open playground. Dev loops can launch straight into it with
`INFINITUS_PLAYGROUND=1 ./run-unbundled.sh`.

Drive it from the shell with `tools/playctl` — the playground polls a
command file and acknowledges each line, so scripts (and coding agents)
can flip knobs and replay animations without touching the mouse:
`playctl theme rpg`, `playctl layout stacked`, `playctl drop fable`,
`playctl kill`, `playctl dead` / `revive`, `playctl scenario solo`,
`playctl refresh`,
`playctl themes`, and `playctl shot out.png` to capture the window
by its CGWindowID.

Everything inside is sandboxed twice. The embedded popup is the real
`MenuContent`, but it runs a **private AppModel pinned to the bundled
`demo-cswap` script** — never the real engine; switching, rotating and
reordering touch demo state only, and every outward side effect
(snapshot cache, notifications, resume nudges, sync) is suppressed. The
knobs write to a **throwaway defaults suite** seeded from your live
settings — choices persist across playground opens, "Reset knobs" falls
back to the seed, and your real prefs never change.

The control rail drives the real pipelines, not canned replays:

- **Play dead / revived / drop (5h, 7d, Fable)** — tmp-file hooks
  (`$TMPDIR/infinitus-demo-*`) pin one of the demo windows' numbers and
  the ordinary refresh diff plays the rest: death beat, revival fanfare,
  HP-drop drama, spring refill.
- **Play account switch / Replay intro** — a real engine switch on the
  demo fleet; the celebration fires from the active-number diff.
- **Scenario** — Normal / Empty fleet / All dead / One account / Two
  accounts / No engine / Two engines: the fleet shapes that otherwise
  need real accounts or waits, one click each.
- **Layout / size / compact / theme / pace fire / intro** — the same
  knobs as Settings, sandboxed.

Below the popup sit self-contained demos: the three pace-fire styles
side by side under one heat dial with a zoom slider, HP drops, window
resets, and the inline flashes.

Workflow: keep it open under `./dev.sh`, then point whatever you're
iterating on at the demo row that exercises it — echo's Dragon bar sits
at 77% forever (the RPG theme's All Lucky 7s fever), bravo burns hot,
foxtrot mild, charlie is dead, golf wants a re-login. Nothing you do
here can touch a real account.

## Architecture rule

Everything is Swift; the engine stays fully isolated behind
`cswap … --json` subprocesses. The app never reads engine internals from
disk.

## Themes

Every theme reskins the whole row: gauge labels, the model name, the
active / next / dead markers, and the reset countdown wording.

| Theme | "Fable" becomes | active · next · dead | ready / resetting |
|---|---|---|---|
| Off — plain numbers | Fable | — | — |
| RPG — HP/MP gauges + gold | Dragon | 👑 🎲 💀 | full HP / respawning… |
| Movie — reels & box office | Epic | 🌟 🍿 🔚 | now showing / premiering… |
| Hades — blades & darkness | Hydra | 🌿 🕯 ☠ | unscathed / raising the dead… |
| Metal Gear — tactical espionage | FOXHOUND | 🐍 🎯 ☠ | all clear / extraction inbound… |
| AI Agentic — tokens & context | frontier | 🧠 ⏭ 🔌 | ready to ship / rate limit lifting… |
| Classic SWE — hand-written, no AI | mainframe | ⌨️ ⏭ 🐛 | compiles clean / recompiling… |
| Sci-Fi — warp cores & shields | Mothership | 🧑‍🚀 📡 💥 | all systems go / recharging… |
| Wild West — six-guns & gold rush | Outlaw | 🏇 🌵 🪦 | saddled up / sun's rising… |
| Cyberpunk — chrome & neon | Netrunner | ⚡ 🕶 💀 | jacked in / rebooting… |
| Gothic — candles & cathedrals | Vampire Lord | 🕯 🌹 ⚰️ | immortal / tolling midnight… |
| Musical — tempo & encores | Maestro | 🎷 🎻 🔇 | in tune / tuning up… |
| Planet Earth — wild documentary | Blue Whale | 🦁 🦋 🦴 | thriving / migrating… |
| Cosmos — stars & black holes | Galaxy | 🪐 🔭 🕳 | shining / orbiting back… |
| Ocean — tides & deep water | Leviathan | ⛵ 🐬 ⚓ | smooth sailing / tide turning… |

### Gallery

The same five-account demo fleet under every theme (pop-out window,
wide layout; charlie is out of their weekly window).

**Off — plain numbers**

![Off — plain numbers](docs/themes/off.png)

**RPG — HP/MP gauges + gold**

![RPG — HP/MP gauges + gold](docs/themes/rpg.png)

**Movie — reels & box office**

![Movie — reels & box office](docs/themes/movie.png)

**Hades — blades & darkness**

![Hades — blades & darkness](docs/themes/hades.png)

**Metal Gear — tactical espionage**

![Metal Gear — tactical espionage](docs/themes/mgs.png)

**AI Agentic — tokens & context**

![AI Agentic — tokens & context](docs/themes/agent.png)

**Classic SWE — hand-written, no AI**

![Classic SWE — hand-written, no AI](docs/themes/swe.png)

**Sci-Fi — warp cores & shields**

![Sci-Fi — warp cores & shields](docs/themes/scifi.png)

**Wild West — six-guns & gold rush**

![Wild West — six-guns & gold rush](docs/themes/west.png)

**Cyberpunk — chrome & neon**

![Cyberpunk — chrome & neon](docs/themes/cyber.png)

**Gothic — candles & cathedrals**

![Gothic — candles & cathedrals](docs/themes/gothic.png)

**Musical — tempo & encores**

![Musical — tempo & encores](docs/themes/musical.png)

**Planet Earth — wild documentary**

![Planet Earth — wild documentary](docs/themes/earth.png)

**Cosmos — stars & black holes**

![Cosmos — stars & black holes](docs/themes/cosmo.png)

**Ocean — tides & deep water**

![Ocean — tides & deep water](docs/themes/ocean.png)

Built-in row themes live in `Sources/InfinitusCore/RowTheme.swift`; add your
own in `~/Library/Application Support/Infinitus/themes.json`, or share one
through [`themes/`](themes/README.md) with a pull request.

## Credits

Inspired by [CodexBar](https://github.com/steipete/CodexBar) (MIT) —
the menu-bar-native take on AI usage limits, and the shape of this
README.

## License

MIT — by [deathemperor](https://github.com/deathemperor) · [huuloc.com](https://huuloc.com)
