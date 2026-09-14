# Install Infinitus

Infinitus runs coding agents on your computer and lets you control them from its
desktop, web, or mobile app. Set up the machine where the agents will work first.

Every build comes from a [GitHub release](https://github.com/deathemperor/infinitus/releases).
There is no npm package: `npx t3` installs upstream's T3 Code, not Infinitus.

You need an installed, authenticated provider before starting a thread. You can
launch Infinitus and configure providers afterwards.

## Desktop app

Download `Infinitus-<version>-arm64.dmg` from the
[latest release](https://github.com/deathemperor/infinitus/releases/latest). It is
built for Apple Silicon Macs and includes its server, so the Mac needs nothing
else. In-app updates come from the same releases.

## Headless server (Linux)

One command installs the server as a self-contained executable — no Node.js:

```bash
curl -fsSL https://infinitus.run/install.sh | sh
```

It takes the newest release's `t3-<version>-linux-<arch>.tar.gz` (releases cut
after 0.5.0-alpha.11 attach them, with `SHA256SUMS`), verifies it, unpacks it
under `~/.infinitus/runtime` and links `t3` into `~/.local/bin`. Then run:

```bash
t3
```

This starts the server and opens the local web app. Run `t3 --help` for
command-line options, `t3 update` for a newer release, and see
[Running in the background](./background-service.md) to keep it running as a
service. You can also download an archive from a
[release](https://github.com/deathemperor/infinitus/releases) yourself and run
its `./t3`.

A Linux machine you reach over SSH from the desktop app needs none of this: the
desktop installs the matching server on it by itself.

## Build from source

There is no server archive for macOS or Windows yet. To run a standalone server
there, build it from source. You need Node.js 24 and `vp` (see
[Install vp](https://github.com/deathemperor/infinitus#install-vp)):

```bash
git clone https://github.com/deathemperor/infinitus
cd infinitus && vp i && vp run build:desktop
node apps/server/dist/bin.mjs
```

A server run this way is a plain Node program: the background service does not
apply, so update it with `git pull` and a rebuild, and start it however you run
other Node processes.

### Windows Subsystem for Linux

Choose a WSL distro in **Settings → Connections** to run agents and projects
there. Install Node.js and provider CLIs inside that distro. Infinitus installs its
matching server runtime there automatically; the first launch after an app
update can take longer.

### Open a project from a terminal

`t3 app` opens a new thread for the current directory in a running desktop
app. It needs a `t3` on the Mac, and no macOS server archive is published yet,
so this is not available on Infinitus for now.

## Mobile app

Install the T3 Code app from the
[App Store](https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824) or
[Google Play](https://play.google.com/store/apps/details?id=com.t3tools.t3code).
The phone connects to a server on another machine. Follow
[remote access](./remote-access.md) to link it through T3 Connect or a pairing URL.

If the app crashes during launch, open Settings → Diagnostics on the next launch
that succeeds. It lists startup crashes from the last 7 days with the error and
component stack that store crash reports leave out. Copy the report and paste it
into a GitHub issue. Error messages can quote values from the app, so read it over
before sharing.

## Providers

Open **Settings → Providers** in the web or desktop app, select the environment,
and enable the provider you want. Installation, login, and configuration belong
to that environment's machine, even when you connect from a phone or another
computer.

| Provider    | Install and authenticate                                                                     |
| ----------- | -------------------------------------------------------------------------------------------- |
| Codex       | Install [Codex CLI](https://developers.openai.com/codex/cli), then run `codex login`.        |
| Claude      | Install [Claude Code](https://claude.com/product/claude-code), then run `claude auth login`. |
| Cursor      | Install [Cursor CLI](https://cursor.com/cli), then run `agent login`.                        |
| Grok Build  | Install [Grok Build CLI](https://x.ai/cli), then run `grok login`.                           |
| OpenCode    | Install [OpenCode](https://opencode.ai), then run `opencode auth login`.                     |
| Antigravity | Install and sign in with Google from the provider settings.                                  |

Provider CLIs must be on the server's `PATH`. If Infinitus cannot find one, set its
**Binary path** in provider settings, especially when using a version manager.
Cursor's executable is `cursor-agent`, although its login command is
`agent login`. Antigravity can use its managed runtime without a `PATH` entry.

When a provider CLI is behind its latest release, its provider card shows the
available version. **Update now** appears only when Infinitus can tell which
installer owns the CLI (its own update command, Homebrew, or a global npm, pnpm,
bun, or Vite+ install) and runs that installer. Otherwise update the CLI the same
way you installed it. Homebrew installs compare against the version Homebrew
offers, which can trail the npm release by a few hours.

Add another provider instance for a separate account or configuration. Each
instance can have its own environment variables, such as API keys or a custom
base URL. Mark secret values as sensitive; after saving, Infinitus does not display
their original values.

For provider-specific setup and accounts, see [Codex](./providers-codex.md),
[Claude](./providers-claude.md), [OpenCode](./providers-opencode.md), and
[Antigravity](./providers-antigravity.md).

## Next steps

- [Working with threads](./thread-sidebar.md): start tasks and organize parallel work.
- [Permission modes](./permission-modes.md): choose when agents ask before acting.
- [Remote access](./remote-access.md): connect from another device.
- [Running in the background](./background-service.md): keep a Linux or macOS host available.
- [Updating](./updating.md): update the app and connected servers.
