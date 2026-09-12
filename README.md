# Infinitus

Infinitus is one product on three screens: the macOS menu bar app that runs your Claude Code accounts (usage windows, swapping, the sessions on the Mac), the desktop and web app that drive the agents, and the phone app. This repository's `main` holds the desktop, web and phone apps and their server; the menu bar app lives in [`apps/mac`](apps/mac/README.md), and one `v<version>` tag releases all of them together (#823). Site: [infinitus.run](https://infinitus.run).

What the desktop, web and phone apps add to the agent client:

- **Accounts page** — every engine's fleet with per-account usage bars, the switch / hold / star / rename actions, the forecast of the next reset, and lapsed AWS and gcloud sign-ins with their device codes.
- **Settings › Infinitus** — the menu bar app's preferences, notification routes, paired devices (the phone QR code and the tunnel), engines, profiles, lock and team, edited from the browser.
- **Sidebar** — an Accounts pill with the active account and its fullest window, and a Sessions group listing the Mac's Claude Code sessions, the ones waiting on you first, each row's permission mode settable in place.
- **Command palette** — "Open accounts".
- **Event toasts** — the engine's events (a swap, a reset, a session that needs you) surface as toasts in the app shell.
- **Phone** — Accounts and Sessions per paired Mac, and a Live Activity the Mac drives while an agent works.
- **Desktop** — the `run.infinitus.desktop` app, state under `~/.infinitus`, the menu bar app nested as a login item, and an `infinitus` update channel fed by the one GitHub release per `v<version>` tag.

Install: `Infinitus-<version>-arm64.dmg` from the [latest release](https://github.com/deathemperor/infinitus/releases/latest) is the desktop app with the menu bar app nested inside as a login item — one download. The menu bar app alone: `brew install --cask deathemperor/tap/infinitus` (or `Infinitus-<version>.zip` from the same release); Linux gets `infinitus-tray-linux-x86_64` / `-aarch64` and `infinitus-omarchy.tar.gz` beside them. The engine is [swapd](https://github.com/deathemperor/swapd).

How the apps talk to the menu bar app: only through its control socket (`INFINITUS_CONTROL_SOCKET` overrides the per-platform default), one JSON line each way; the engine's own files are never read.

For contributors: this tree builds on [T3 Code](https://github.com/pingdotgg/t3code), the upstream project. Upstream's `main` is merged in daily by the [Upstream sync](.github/workflows/upstream-sync.yml) workflow as a pull request; the rules, registration points and the list of Infinitus-only files are in [INFINITUS.md](INFINITUS.md). Everything below the rule is upstream's README, untouched.

---

T3 Code is an "agent harness control surface". It enables control of the agents on your machine with a best-in-class mobile app ([iOS](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824), [Android](https://play.google.com/store/apps/details?id=com.t3tools.t3code)), [web app](https://app.t3.codes) and [Electron-based desktop app](https://t3.codes).

Works with your subscriptions on Claude Code, Codex, Cursor, Grok Build, OpenCode, and Google Antigravity. If they're set up on your computer, T3 Code can control them.

## "Wait, what are you selling me?"

Nothing. We built T3 Code because we wanted the best possible development experience with agents. We were inspired by existing solutions like the Codex desktop app, Conductor, Claude Desktop and Cursor Glass, but none met our bar.

We wanted something performant, remote-ready, and truly open. If we ever go the wrong direction, we want you to have everything you need to fork and build the editor that you want.

## Installation

> [!WARNING]
> T3 Code currently supports Codex, Claude, Cursor, Grok Build, OpenCode, and Antigravity. Install and authenticate at least one provider before use:
>
> - Codex: install [Codex CLI](https://developers.openai.com/codex/cli) and run `codex login`
> - Claude: install [Claude Code](https://claude.com/product/claude-code) and run `claude auth login`
> - Cursor: install [Cursor CLI](https://cursor.com/cli) and run `agent login`
> - Grok Build: install [Grok Build CLI](https://x.ai/cli) and run `grok login`
> - OpenCode: install [OpenCode](https://opencode.ai) and run `opencode auth login`
> - Antigravity: enable it in Settings, then use **Install Antigravity** and **Sign in with Google**. No CLI is required.

### Try it out (install-free)

The easiest way to test T3 Code is to run the server in your terminal (requires Node.js 22.16+, 23.11+, or 24.10+):

```bash
npx t3@latest
```

This will launch T3 Code's backend on your machine as well as the local web app to control your agents.

Tip: Use `npx t3@latest --help` for the full CLI reference.

### Desktop app

Install the latest version of the desktop app from [GitHub Releases](https://github.com/pingdotgg/t3code/releases), or from your favorite package registry:

#### Windows (`winget`)

```bash
winget install T3Tools.T3Code
```

#### macOS (Homebrew)

```bash
brew install --cask t3-code
```

#### Arch Linux (AUR)

Stable:

```bash
yay -S t3code-bin
```

Nightly:

```bash
yay -S t3code-nightly-bin
```

The AUR packaging is maintained in this repository under [`packaging/aur`](./packaging/aur).

## Some notes

We are very very early in this project. Expect bugs.

We are (mostly) not accepting contributions yet. Small fixes may be considered. Big features will not be.

## Documentation

Full docs live in [docs/](./docs). There's no docs site yet.

- [Install and first run](./docs/user/install.md)
- [Permission modes](./docs/user/permission-modes.md)
- [Keyboard shortcuts](./docs/user/keybindings.md)
- [Project settings](./docs/user/project-settings.md)
- [Remote access from a phone or another machine](./docs/user/remote-access.md)
- [Keeping app and server in sync](./docs/user/updating.md)
- [Source control integrations](./docs/user/source-control.md)
- Multiple accounts: [Codex](./docs/user/providers-codex.md) · [Claude](./docs/user/providers-claude.md)
- [Run T3 Code as a background service](./docs/user/background-service.md)

Building from source? Start at [docs/internals/overview.md](./docs/internals/overview.md).

## If you REALLY want to contribute still.... read this first

### Install `vp`

T3 Code uses Vite+ so you'll need to install the global `vp` command-line tool.

#### macOS / Linux

```bash
curl -fsSL https://vite.plus | bash
```

#### Windows

```bash
irm https://vite.plus/ps1 | iex
```

Checkout their getting started guide for more information: https://viteplus.dev/guide/

### Install dependencies

```bash
vp i
```

Read [CONTRIBUTING.md](./CONTRIBUTING.md) before reporting a bug or opening a PR.

Have a feature request? Start an [Ideas discussion](https://github.com/pingdotgg/t3code/discussions/categories/ideas).

Need support? Join the [Discord](https://discord.gg/jn4EGJjrvv).
