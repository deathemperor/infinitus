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

<<<<<<< HEAD
It takes the newest release's `infinitus-<version>-linux-<arch>.tar.gz` (releases cut
after 0.5.0-alpha.11 attach them, with `SHA256SUMS`), verifies it, unpacks it
under `~/.infinitus/runtime` and links `infinitus` into `~/.local/bin`. Then run:
=======
On Windows, in PowerShell:

```powershell
irm https://t3.codes/install.ps1 | iex
```

This installs the `t3` binary to `~/.local/bin`. If that folder is not on your
`PATH` yet, the installer says so and, for zsh, bash on Linux, and fish, prints
a command to add it. On Windows, `t3` works in the same PowerShell window right
away; add the folder to your `PATH` for new windows. If a `t3` that the
installer or the desktop app did not create is already there, it leaves that
one alone and stops. Set `T3CODE_CHANNEL=nightly` to install the nightly train, or
`T3CODE_VERSION` to pin an exact version.

| Task                                  | Command                                                                 |
| ------------------------------------- | ----------------------------------------------------------------------- |
| Start the server and open the web app | `t3`                                                                    |
| Start the server without a browser    | `t3 serve`                                                              |
| Use it from your other devices        | `t3 up` ([details](./remote-access.md))                                 |
| Keep it running in the background     | `t3 service install` ([details](./background-service.md))               |
| Move to the newest release            | `t3 update`                                                             |
| Reclaim database space                | `t3 doctor` ([details](./background-service.md#reclaim-database-space)) |
| Remove it again                       | `t3 uninstall`                                                          |

Run `t3 help` or `t3 --help` for the full reference. To start in a new working
directory, use an explicit path such as `t3 ./my-project`. A bare directory name
is accepted only if it already exists.

If `t3` or `t3 start` reports an already running server, connect to that server
instead. Stop it before starting a replacement, or use a different `--base-dir`
for an independent server.

To try Infinitus once without installing it, run `npx t3@latest` instead (needs
Node.js for `npx`). It offers to install the `t3` command first. If you say no,
it asks again at the next minor release, and `npx t3 install` installs it later.
`npx t3` always runs the version npm picked, even when a `t3` is installed. On
the nightly train, run your installed `t3` (for example `t3 connect`), not
`npx t3`, which runs the latest stable release.

### Intel Macs

There is no `t3` executable for Intel Macs (the desktop app is available). To
run a server there, build it from source with `vp`, which provides the Node version it needs
([Install vp](../operations/development.md#first-checkout)):
>>>>>>> upstream-sync-2d8a843e6b-upstream-renamed

```bash
infinitus
```

This starts the server and opens the local web app. If your shell reports
`command not found`, `~/.local/bin` is not on your `PATH` yet; the installer
prints the line to add. Set `T3CODE_VERSION` to pin an exact release.

| Task                                  | Command                                                                        |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| Start the server and open the web app | `infinitus`                                                                    |
| Start the server without a browser    | `infinitus serve`                                                              |
| Use it from your other devices        | `infinitus up` ([details](./remote-access.md))                                 |
| Keep it running in the background     | `infinitus service install` ([details](./background-service.md))               |
| Move to the newest release            | `infinitus update`                                                             |
| Reclaim database space                | `infinitus doctor` ([details](./background-service.md#reclaim-database-space)) |
| Remove it again                       | `infinitus uninstall`                                                          |

Run `infinitus help` or `infinitus --help` for the full reference. To start in a
new working directory, use an explicit path such as `infinitus ./my-project`. A
bare directory name is accepted only if it already exists.

If `infinitus` or `infinitus start` reports an already running server, connect
to that server instead. Stop it before starting a replacement, or use a
different `--base-dir` for an independent server.

You can also download an archive from a
[release](https://github.com/deathemperor/infinitus/releases) yourself and run
its `./infinitus`.

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

<<<<<<< HEAD
A server run this way is a plain Node program: the background service does not
apply, so update it with `git pull` and a rebuild, and start it however you run
other Node processes.
=======
`t3 update` and the background service do not apply to a server run this way;
update it with `git pull` and a rebuild.

## Desktop app

Download a release from [GitHub Releases](https://github.com/pingdotgg/t3code/releases),
or use a package manager:

| Platform           | Install                                                      |
| ------------------ | ------------------------------------------------------------ |
| Windows            | `winget install T3Tools.T3Code`                              |
| Windows (Scoop)    | `scoop install extras/t3code`                                |
| macOS              | `brew install --cask t3-code`                                |
| Debian, Ubuntu     | `sudo apt install ./T3-Code-*.deb`                           |
| Arch Linux         | `yay -S t3code-bin`                                          |
| Arch Linux nightly | `yay -S t3code-nightly-bin`                                  |
| Nix                | `nix profile add github:NixOS/nixpkgs/nixos-unstable#t3code` |

### Linux

AppImage and `.deb` downloads are available for x86_64 and ARM64. Check your
architecture with `uname -m`: for `x86_64`, choose a file ending in
`x86_64.AppImage` or `amd64.deb`; for `aarch64`, choose `arm64.AppImage` or
`arm64.deb`.

To launch an AppImage, open a terminal in its download folder. Replace
`T3-Code.AppImage` below with the exact filename you downloaded:

```bash
chmod +x ./Infinitus-Code.AppImage
./Infinitus-Code.AppImage
```

The `.deb` updates itself like the other desktop builds. It asks for your
password to install each update. If your desktop has no password prompt, the
update fails. Download the new `.deb` and install it the same way.

The AUR packages currently support x86_64 only; on ARM64, use the AppImage.
Update AUR installs with your AUR helper, such as `yay -Syu`, instead of the
in-app updater.

### Nix (nixpkgs)

Infinitus is maintained in [nixpkgs](https://github.com/NixOS/nixpkgs/tree/nixos-unstable/pkgs/by-name/t3/t3code).
The command above installs from `nixos-unstable` and requires Nix 2.30 or later with
`nix-command` and `flakes` enabled. Launch the desktop app with `t3code-desktop`;
the package also includes the `t3` command.

On NixOS, you can instead add the package to your system configuration, using
a nixpkgs revision that includes `t3code`:

```nix
environment.systemPackages = [ pkgs.t3code ];
```

Apply the change with `sudo nixos-rebuild switch`. For Home Manager, add
`pkgs.t3code` to `home.packages` and run `home-manager switch`.

Update a profile installation with `nix profile upgrade t3code`. For NixOS or
Home Manager, update your configuration's nixpkgs input or channel and rebuild.
Nix manages both the desktop app and the bundled
`t3` command; use Nix to update them instead of the in-app updater or `t3 update`.
>>>>>>> upstream-sync-2d8a843e6b-upstream-renamed

### The `t3` command

The desktop app includes the `t3` command-line tool. A new install sets it up
on first launch; after an update, or any time, choose **Install** next to
**t3 command** in **Settings → About**. On macOS and Linux it adds a `t3` link
in `~/.local/bin` (or `~/bin`); on Windows it adds the app's command folder to
your `PATH`. Open a new terminal afterwards. If the folder is not on your
`PATH`, **Add to PATH** on the Welcome page or in **Settings → About** adds one
line to your shell's startup file. **Remove** takes it off, and the app does not
add it again. If you already have another `t3`, it stays as it is.

### Windows Subsystem for Linux

Choose a WSL distro in **Settings → Sharing & access** to run agents and projects
there. Install Node.js and provider CLIs inside that distro. Infinitus installs its
matching server runtime there automatically; the first launch after an app
update can take longer.

### Open a project from a terminal

`infinitus app` opens a new thread for the current directory in a running desktop
app. It needs a `infinitus` on the Mac, and no macOS server archive is published yet,
so this is not available on Infinitus for now.

### Drop a folder on the sidebar

Drag one or more folders from Finder, Explorer, or your file manager onto the
sidebar. Each one opens as a project on this computer, the same as `t3 app`.
Files dropped on a thread still attach to that thread. Browsers do not share
folder paths, so in the web app use **Add project** instead.

## Mobile app

The Infinitus phone app is not on a store: it is installed from a build
(TestFlight or a device build). The phone connects to a server on another
machine. Follow
[remote access](./remote-access.md) to link it through Infinitus Connect or a pairing URL.

Store links and QR codes are also available in **Settings → About → Mobile app**
on web and desktop. The store apps work with both stable and Nightly servers. Test builds are optional:

- **iPhone and iPad:** TestFlight is invite-only.
- **Android:** download an APK from the
  [Android beta releases](https://github.com/pingdotgg/t3code/releases?q=android-beta-).

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

| Provider    | Install and authenticate                                                                                                                                  |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Codex       | [Connect with ChatGPT](./providers-codex.md#connect-with-chatgpt), or install [Codex CLI](https://developers.openai.com/codex/cli) and run `codex login`. |
| Claude      | Install [Claude Code](https://claude.com/product/claude-code), then run `claude auth login`.                                                              |
| Cursor      | Install [Cursor CLI](https://cursor.com/cli), then run `agent login`.                                                                                     |
| Grok Build  | Install [Grok Build CLI](https://x.ai/cli), then run `grok login`.                                                                                        |
| Kiro        | Install [Kiro CLI](https://kiro.dev/docs/cli/), then run `kiro-cli login`.                                                                                |
| OpenCode    | Install [OpenCode](https://opencode.ai), then run `opencode auth login`.                                                                                  |
| Antigravity | Install and sign in with Google from Infinitus's provider settings.                                                                                       |
| Pi          | Install [Pi](./providers-pi.md#set-up-pi) with Node.js 22.19 or newer, then run `pi` and `/login`.                                                        |
| Muse Code   | Install [Muse Code](https://dev.meta.ai/docs/muse-code) on the server, run `muse login`, then enable it in Settings → Providers.                          |
| fx          | Install [fx](https://fx.sh) with `curl -fsSL https://fx.sh/setup.sh \| bash`, then run `fx login`.                                                        |

Provider CLIs must be on the server's `PATH`. If Infinitus cannot find one, set its
**Binary path** in provider settings, especially when using a version manager.
Cursor's executable is `cursor-agent`, although its login command is
`agent login`. Codex connected through ChatGPT and Antigravity can use their
managed runtimes without a `PATH` entry.

Infinitus warns when a provider version has known compatibility problems with your
release. Check **Settings → Providers** on that environment for the recommended
version or range. When its package manager supports installing a specific version,
you can install the recommendation there. Otherwise use the provider's installer
on the environment's machine. An unlisted version is unverified.

When a provider CLI is behind its latest release, its provider card shows the
available version. **Update now** runs the installer that owns the CLI
(Homebrew, mise, or a global npm, pnpm, Yarn, Bun, Volta, or Vite+ install), or
the CLI's own update command when Infinitus cannot tell. Claude, Codex, and
OpenCode installs Infinitus cannot identify stay manual: update them through the
installer you used. Infinitus runs `mise upgrade`
only for a tool your mise config requests as `latest` when the provider's binary
path is a mise shim or under the tool's `installs/<tool>/latest` link; update a
pinned version, or a path into one version's directory, through mise yourself.
Update a CLI installed with Nix through Nix.
Cursor and Antigravity update with Infinitus. Homebrew and Chocolatey installs
compare against the version their package manager offers, which can trail the
npm release; update Claude installed with Chocolatey through Chocolatey.

The managed runtimes for Antigravity and for Codex connected through ChatGPT
first install the release Infinitus tested. When Infinitus finds a newer compatible
release, their setup in **Settings → Providers** offers an update.

Add another provider instance for a separate account or configuration. Each
instance can have its own environment variables, such as API keys or a custom
base URL. Mark secret values as sensitive; after saving, Infinitus does not display
their original values.

For provider-specific setup and accounts, see [Codex](./providers-codex.md),
[Claude](./providers-claude.md), [OpenCode](./providers-opencode.md),
[Antigravity](./providers-antigravity.md), [Kiro](./providers-kiro.md),
[Pi](./providers-pi.md), [Muse Code](./providers-muse.md), and [fx](./providers-fx.md).

### Provider check timeouts

If a provider works in its CLI but Infinitus reports a timeout while checking it,
allow more time in the Infinitus server's environment. For example, give Codex and
Claude readiness checks 60 seconds:

```bash
T3CODE_CODEX_PROBE_TIMEOUT_MS=60000 T3CODE_CLAUDE_PROBE_TIMEOUT_MS=60000 t3 serve
```

For a remote environment, set these on the machine running the Infinitus server.
Keep them in your launcher or service configuration to retain them across
updates, then restart the server. For systemd, add
`Environment=T3CODE_CODEX_PROBE_TIMEOUT_MS=60000` under `[Service]` in a service
override, reload systemd, and restart the service. Provider instances can also
set their own overrides in Settings → Providers.

Each variable extends that provider's readiness-probe deadlines; a phase whose
default is already longer keeps its default. Providers with several phases can
take longer than one deadline in total. Values must be whole milliseconds no
greater than 2147483647; unset or invalid values keep the defaults.

| Provider            | Environment variable                   |
| ------------------- | -------------------------------------- |
| Codex               | `T3CODE_CODEX_PROBE_TIMEOUT_MS`        |
| Claude              | `T3CODE_CLAUDE_PROBE_TIMEOUT_MS`       |
| Cursor              | `T3CODE_CURSOR_PROBE_TIMEOUT_MS`       |
| Antigravity         | `T3CODE_ANTIGRAVITY_PROBE_TIMEOUT_MS`  |
| Grok                | `T3CODE_GROK_PROBE_TIMEOUT_MS`         |
| Kiro                | `T3CODE_KIRO_PROBE_TIMEOUT_MS`         |
| fx                  | `T3CODE_FX_PROBE_TIMEOUT_MS`           |
| Pi                  | `T3CODE_PI_PROBE_TIMEOUT_MS`           |
| Muse Code           | `T3CODE_MUSE_PROBE_TIMEOUT_MS`         |
| OpenCode            | `T3CODE_OPENCODE_PROBE_TIMEOUT_MS`     |
| ACP Registry agents | `T3CODE_ACP_REGISTRY_PROBE_TIMEOUT_MS` |

Longer deadlines also take longer to report a stalled check. These overrides
cover readiness and discovery, including OpenCode server startup. Usage and
config enrichment retain their own shorter limits. Turn execution, package
installation, update checks, and shutdown limits keep their existing behavior.

## Next steps

- [Working with threads](./thread-sidebar.md): start tasks and organize parallel work.
- [Permission modes](./permission-modes.md): choose when agents ask before acting.
- [Remote access](./remote-access.md): connect from another device.
<<<<<<< HEAD
- [Running in the background](./background-service.md): keep a Linux or macOS host available.
- [Updating](./updating.md): update the app and connected servers.
=======
- [Running in the background](./background-service.md): keep a host available.
- [Updating Infinitus](./updating.md): update the app and connected servers.
>>>>>>> upstream-sync-2d8a843e6b-upstream-renamed
- [Managed policy](./managed-policy.md): configure Infinitus for everyone on a machine.
