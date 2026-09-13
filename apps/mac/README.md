# Infinitus

**Every Claude account in one menu bar — swap before you stall.**

May your limits never bind.

[![Release](https://img.shields.io/github/v/release/deathemperor/infinitus)](https://github.com/deathemperor/infinitus/releases)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
[![Homebrew](https://img.shields.io/badge/homebrew-deathemperor%2Ftap-orange)](https://github.com/deathemperor/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

![Infinitus demo — layouts, compact mode, pop-out, live theme switching](docs/demo.gif)

A macOS menu bar app (Swift/SwiftUI) over the
[swapd](https://github.com/deathemperor/swapd) engine: live
usage gauges for a whole fleet of Claude accounts, auto-switch awareness,
and a one-click rotate — wrapped in themes from RPG to Wild West.

## Why

Claude usage windows run out at the worst moment. If you keep more than
one account, the juggling — which one has 5-hour headroom, which weekly
window is about to bind, which one just died — is exactly the kind of
state a menu bar should carry for you. Infinitus shows the whole fleet at
a glance and swaps before you stall.

## Install

Infinitus is alpha software (0.5.0-alpha.1): it runs its author's fleet
all day, but expect rough edges — please file issues.

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
drop `Infinitus.app` into `/Applications`. The same release carries the
whole desktop app, `Infinitus-<version>-arm64.dmg`, with the menu bar app
nested inside as a login item — one download for both.

The `infinitusctl` CLI ships inside the bundle at
`Infinitus.app/Contents/MacOS/infinitusctl`, with `ictl` beside it as the
short name for the same binary — Homebrew links them onto your PATH; from
a release, symlink them yourself
(`ln -sf /Applications/Infinitus.app/Contents/MacOS/{infinitusctl,ictl} /usr/local/bin/`).

### Linux — engine CLI + Waybar module (Omarchy-ready)

The menu bar app is AppKit, but its Swift core ports:
`infinitus-tray` renders the same fleet — themes, sentinel notes,
one-click rotate — as a Waybar module or Quickshell plugin for
[Omarchy](https://omarchy.org) and any Waybar desktop
(see [`packaging/omarchy/`](packaging/omarchy/README.md)).
The engine is the same `swapd` the Mac app drives (`swapd add`,
`swapd auto`, `swapd list --json`):

```sh
cargo install --git https://github.com/deathemperor/swapd swapd
```

Arch users get the prebuilt tray from
[`packaging/aur/infinitus-tray-bin`](packaging/aur/); every release also
ships static `infinitus-tray-linux-x86_64` / `-aarch64` binaries and
`infinitus-omarchy.tar.gz`.

> **Container-tested only.** The PKGBUILD (`archlinux` image,
> `makepkg -s`) and the static `infinitus-tray` binary (Arch Linux ARM image, themed Waybar JSON
> against a demo fleet) all run in containers — no real accounts or
> desktop session were involved. Reports from actual Linux desktops
> welcome.

### Requirements

- macOS 14+ (best on macOS 26 — the glass chrome uses it)
- the `swapd` CLI on PATH
  (`cargo install --git https://github.com/deathemperor/swapd swapd`) —
  the app's first-run card shows the line and adds your first account

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
- **Themes** — RPG, Movie, Hades, Metal Gear, Sci-Fi, Cyberpunk, Ocean and more, picked in the desktop app's Settings › Infinitus › Themes, your own via `themes.json`; the phone follows.
- **Themed menu bar** — the loop in the theme's color with its icon, a glow on switch, death and revival, an ember breath while burning ahead of pace.
- **Glass popup** — real backdrop blur in every focus state with a transparency dial, and a launch intro.
- **Right-click menu** on the bar icon — open the desktop app, rotate, refresh, capture, pin, pop out, settings, restart, quit.
- **Sessions & status chips** — the live Claude Code session count with its busy/idle split, engine status, auto-mode.
- **Resume nudges** (opt-in) — sessions a limit stopped get a "continue" typed into their terminal or sent over the peer socket once an account works again; sub-agent limits get the same nudge once an account with headroom is active.
- **Revival probes** — when a countdown ends the Mac asks the engine again at once, and "<account> is back" says so, flagged when Anthropic reset early.
- **Cost estimates** — 7-day per-account API-list-price estimates, never billing truth.
- **iCloud settings sync** and file export/import, never credentials.
- **Push notifications** — switch and limit events in Notification Center and on the phone.
- **Pop-out window, compact mode, three layouts, popup scaling** — the pop-out remembers its spot.
- **Sessions by name** — `/rename` names label the rows on the Mac and the phone, with branch, model, kind and output size.
- **Phone companion, four ways in** — Wi-Fi (Bonjour), Tailscale, your own Cloudflare tunnel or a free quick tunnel; one QR carries every route; pair more than one Mac.
- **Versions on the phone** — Settings shows both apps' versions, updates the Mac with one tap (brew builds), and says when a newer phone build is out.
- **Session chat from the phone** — each transcript as a chat with markdown, tool chips and sub-agent cards; reply, attach photos and files, answer prompts.
- **Start a session from the phone** — a repository, the engine, a first prompt; the Mac opens cmux or Terminal and the chat follows. Siri too.
- **Widgets in your theme** — home and lock-screen widgets show the active account's windows, what's waiting, and the revival countdown; "Fleet on a Mac" shows a paired Mac of your choice and its tap opens that Mac's sessions.
- **AWS and gcloud sign-in from the phone** — an expired `aws login` or `gcloud auth login` shows up on both, the phone runs it (passkeys for AWS, a paste-back code for gcloud), and the session is told to continue.
- **Three engines** — swapd, CLIProxyAPI and 9Router as stacked fleets; policy stays in each engine, the app sets its knobs. swapd is multi-provider: one fleet per provider it holds (Claude, Gemini CLI…), and igniting an account refreshes it at once.
- **Priority mode** — `hold` or `interrupt` gives every fleet a headroom verdict (abundant / low / critical, with hysteresis on the active account's fullest window), so a client can pause background work before a window binds.
- **Preferences over the socket** — `infinitusctl prefs` lists every setting with its type, choices, range and effect; `prefs set` changes one live, from the CLI, the phone or the desktop app.
- **Devices** — every phone that has paired, with its route, when it was last seen and what it holds on this Mac, each with Forget.
- **Desktop app hosting** — the Infinitus desktop app drives the Mac over the control socket (`quit`, `signin-*`, `events --after`, `lock`), and its server rides the companion's quick or named Cloudflare tunnel (`fork_tunnel_*`).
- **"At this pace"** — measured burn per window, when each runs out, a per-account forecast and a plain-words plan for the next reset.
- **Stats**, on the desktop app's Stats page — commits, lines, PRs, messages, sessions, tool calls, waiting time, switches, cost; effort per activity, model, engine and effort setting; tokens/min records; cached vs uncached input and cache savings.
- **Sessions, named and narrated** — unnamed sessions get a Haiku title that follows the work; the phone opens on what's waiting, with Continue.
- **This Mac's name** — Settings › Devices names the Mac for the phone, widgets and crash reports; the default drops macOS's "(7)" suffix.
- **Capture the desktop into a session** — a region or window, a session, a note, delivered like a phone message.
- **Dictate in any language** — Vietnamese in, an editable English draft out, with the session's own terms taught to the recognizer.
- **All accounts limited, handled** — the popup, the desktop app and the phone count down to the first account back, with the sessions waiting to resume.
- **Share → Infinitus from any app** — images, files, a link or text into a session on any paired Mac with a note; your sessions sit in the share sheet's suggestions.
- **Chat headers in three styles** — compact, a stat strip, or Game HUD with a ringed portrait and HP/MP-style bars in the theme's colors.
- **Live Activities that keep moving** — with an APNs key the lock-screen countdown and working card update with the app closed; one pair per paired Mac; the icon follows the theme.
- **Reset and swap alarms on the phone** — local notifications ten minutes before an exhausted account's reset and when a swap is near.
- **Crash reports, on-device** — both apps record their own crashes; any report can go into a session's chat for triage.
- **Randomize names** — every account gets a fresh name from the theme's pool, or one account with the dice beside its name; Tab moves between the name fields.
- **Star & pause anywhere** — right-click a name in the popup, or swipe / long-press on the phone, to star an account or pause its rotation; a paused row shows a play button to resume.
- **Parked** — the Mac asleep or away, the phone still shows the fleet and every transcript, and a message you send waits and goes out when it's back.
- **Every Mac's chats** — a session under another paired Mac opens like any other; what you send goes to that Mac, and waits for it if it's away.
- **Start on any Mac** — the "+" sheet, Past sessions and Siri's Start a session pick which paired Mac runs the session; a Mac that's away keeps its sessions on the phone, marked parked.
- **Profiles** — the desktop app's Infinitus › Profiles settings save named ways to start a session (folder, engine, permissions, model, system prompt, first prompt, tools allowed without asking); the phone, Siri and the Mac's Start a session take one.
- **Review from the phone** — a turn's changes as hunks, a tap comments one, Approve or Request changes goes back to the session.
- **Fork a session** — Past sessions on the Mac and the phone, or `infinitusctl resume-session --fork`, continue a transcript under a new session id.
- **Start a session from the Mac** — the sessions popover takes a profile chip, folder, engine, permissions and a first prompt.
- **Headless sessions** — start a session with no terminal, from the popup, the phone, or as the default; the desktop app, the phone and the browser page are its chat, and its prompts, questions, plans and images reach all three.
- **A browser page for machines without the app** — sessions list, chat with a session, Start a session, at the "Copy Browser Link" address in Settings › Devices.
- **Chat with a session** — from the desktop app (the sidebar's Sessions group, "Move to a thread") or the phone: the live transcript, a composer, its prompts answered.
- **A feed that folds** — tool runs as one line to open, finished turns folded behind "Worked for 13s", one live row while Claude works; the same rows on the Mac, the phone and the browser page.
- **New phone screens (preview)** — Settings › Appearance › "New session screens": a flat thread list with shelves and search, a session as a chat thread with a task sheet under +, thread settings and a git pill.
- **Ignite says what it did** — the plan line reports the window it started or why it failed, and the desktop app's Activity page keeps the log across relaunches.
- **`infinitusctl`** — an agent-facing control CLI: status, fleets, sessions, send, switch, hold, rename, proxy, AWS and gcloud logins, stats, perf, and Infinitus desktop's projects and threads (`threads`, `thread show|send|new|interrupt|release`, `desktop status`); plus an agent-setup guide.

## Privacy

Everything stays on your machine (the phone talks straight to your Mac
over routes you enable; the only thing that ever touches infinitus.run
is a quick tunnel's URL, keyed by a hash of the pairing token — never
the token, never usage). The app talks to the engine through
`swapd … --json` subprocesses and never reads its files (resume nudges
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

## Architecture rule

Everything is Swift; the engine stays fully isolated behind
`swapd … --json` subprocesses. The app never reads engine internals from
disk.

## Themes

Every theme reskins the whole row: gauge labels, the model name, the
active / next / dead markers, the reset countdown wording and the
tokens/minute chip.

| Theme | "Fable" becomes | active · next · dead | ready / resetting | tokens/min |
|---|---|---|---|---|
| Off — plain numbers | Fable | — | — | — |
| RPG — HP/MP gauges + gold | Dragon | 👑 🎲 💀 | full HP / respawning… | 🔮 mana/min |
| Movie — reels & box office | Epic | 🌟 🍿 🔚 | now showing / premiering… | 🎞 reels/min |
| Hades — blades & darkness | Hydra | 🌿 🕯 ☠ | unscathed / raising the dead… | 💀 souls/min |
| Metal Gear — tactical espionage | FOXHOUND | 🐍 🎯 ☠ | all clear / extraction inbound… | 📻 codec/min |
| AI Agentic — tokens & context | frontier | 🧠 ⏭ 🔌 | ready to ship / rate limit lifting… | 🧮 tok/min |
| Classic SWE — hand-written, no AI | mainframe | ⌨️ ⏭ 🐛 | compiles clean / recompiling… | 💻 LOC/min |
| Sci-Fi — warp cores & shields | Mothership | 🧑‍🚀 📡 💥 | all systems go / recharging… | 🛸 warp/min |
| Wild West — six-guns & gold rush | Outlaw | 🏇 🌵 🪦 | saddled up / sun's rising… | 🐎 stampede |
| Cyberpunk — chrome & neon | Netrunner | ⚡ 🕶 💀 | jacked in / rebooting… | 📶 baud |
| Gothic — candles & cathedrals | Vampire Lord | 🕯 🌹 ⚰️ | immortal / tolling midnight… | 🦇 whispers |
| Musical — tempo & encores | Maestro | 🎷 🎻 🔇 | in tune / tuning up… | 🎵 notes/min |
| Planet Earth — wild documentary | Blue Whale | 🦁 🦋 🦴 | thriving / migrating… | 🐝 buzz/min |
| Cosmos — stars & black holes | Galaxy | 🪐 🔭 🕳 | shining / orbiting back… | 🌠 flux/min |
| Ocean — tides & deep water | Leviathan | ⛵ 🐬 ⚓ | smooth sailing / tide turning… | 🌊 knots |

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
