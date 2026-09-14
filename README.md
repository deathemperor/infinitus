# Infinitus

Infinitus is one product on three screens: the macOS menu bar app that runs your Claude Code accounts (usage windows, swapping, the sessions on the Mac), the desktop and web app that drive the agents, and the phone app. This repository's `main` holds the desktop, web and phone apps and their server; the menu bar app lives in [`apps/mac`](apps/mac/README.md), and one `v<version>` tag releases all of them together (#823). Site: [infinitus.run](https://infinitus.run).

What the desktop, web and phone apps add to the agent client:

- **Accounts page** — every engine's fleet with per-account usage bars, the switch / hold / star / rename actions, the forecast of the next reset, and lapsed AWS and gcloud sign-ins with their device codes.
- **Settings › Infinitus** — the menu bar app's preferences, notification routes, paired devices (the phone QR code and the tunnel), engines and lock, edited from the browser.
- **Sidebar** — an Accounts pill with the active account and its fullest window.
- **Command palette** — "Open accounts".
- **Event toasts** — the engine's events (a swap, a reset, every account exhausted) surface as toasts in the app shell.
- **Phone** — Accounts per paired Mac, and the Mac's account alerts as banners.
- **Desktop** — the `run.infinitus.desktop` app, state under `~/.infinitus`, the menu bar app nested as a login item, and in-app updates from the GitHub releases.

Install: `Infinitus-<version>-arm64.dmg` from the [latest release](https://github.com/deathemperor/infinitus/releases/latest) is the desktop app with the menu bar app nested inside as a login item — one download. The menu bar app alone: `brew install --cask deathemperor/tap/infinitus` (or `Infinitus-<version>.zip` from the same release); Linux gets `infinitus-tray-linux-x86_64` / `-aarch64` and `infinitus-omarchy.tar.gz` beside them. The engine is [swapd](https://github.com/deathemperor/swapd).

How the apps talk to the menu bar app: only through its control socket (`INFINITUS_CONTROL_SOCKET` overrides the per-platform default), one JSON line each way; the engine's own files are never read.

For contributors: this tree builds on [T3 Code](https://github.com/pingdotgg/t3code), the upstream project. Upstream's `main` is merged in daily by the [Upstream sync](.github/workflows/upstream-sync.yml) workflow as a pull request; the rules, registration points and the list of Infinitus-only files are in [INFINITUS.md](INFINITUS.md). Everything below the rule is upstream's README, untouched except the Installation section, which describes this product's releases (#1192).

---

T3 Code is an "agent harness control surface". It enables control of the agents on your machine with a best-in-class mobile app ([iOS](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824), [Android](https://play.google.com/store/apps/details?id=com.t3tools.t3code)), [web app](https://app.t3.codes) and [Electron-based desktop app](https://t3.codes).

Works with your subscriptions on Claude Code, Codex, Cursor, Grok Build, OpenCode, and Google Antigravity. If they're set up on your computer, T3 Code can control them.

## "Wait, what are you selling me?"

Nothing. We built T3 Code because we wanted the best possible development experience with agents. We were inspired by existing solutions like the Codex desktop app, Conductor, Claude Desktop and Cursor Glass, but none met our bar.

We wanted something performant, remote-ready, and truly open. If we ever go the wrong direction, we want you to have everything you need to fork and build the editor that you want.

## Installation

Every Infinitus build comes from one [GitHub release](https://github.com/deathemperor/infinitus/releases) of this repository. There is no npm package, Homebrew cask, winget or AUR package for the desktop app; `npx t3` installs upstream's T3 Code, not Infinitus.

> [!WARNING]
> Infinitus drives Codex, Claude, Cursor, Grok Build, OpenCode and Antigravity. Install and sign in to at least one before starting a thread:
>
> - Codex: install [Codex CLI](https://developers.openai.com/codex/cli) and run `codex login`
> - Claude: install [Claude Code](https://claude.com/product/claude-code) and run `claude auth login`
> - Cursor: install [Cursor CLI](https://cursor.com/cli) and run `agent login`
> - Grok Build: install [Grok Build CLI](https://x.ai/cli) and run `grok login`
> - OpenCode: install [OpenCode](https://opencode.ai) and run `opencode auth login`
> - Antigravity: enable it in Settings, then use **Install Antigravity** and **Sign in with Google**. No CLI is required.

### Desktop app (macOS, Apple Silicon)

`Infinitus-<version>-arm64.dmg` from the [latest release](https://github.com/deathemperor/infinitus/releases/latest). It bundles the server and the menu bar app (nested as a login item), updates itself from the releases, and can host your phone, a browser or another desktop. The menu bar app on its own: `brew install --cask deathemperor/tap/infinitus`, or `Infinitus-<version>.zip` from the same release.

### Headless server (Linux)

`curl -fsSL https://infinitus.run/install.sh | sh` installs the newest release's `t3-<version>-linux-<arch>.tar.gz` — the server as one self-contained executable, no Node.js needed — verified against its `SHA256SUMS` (releases cut after 0.5.0-alpha.11 attach them). The desktop app installs the matching one onto a Linux SSH remote by itself. To run one by hand, see [Install](./docs/user/install.md#headless-server-linux) and [Running in the background](./docs/user/background-service.md).

### Not available yet

- A macOS server archive. A Mac either runs the desktop app or a [build from source](./docs/user/install.md#build-from-source); for the same reason a Mac cannot yet be set up as an SSH remote from the desktop.
- Windows server archives.

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
- [Run the server in the background](./docs/user/background-service.md)

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
