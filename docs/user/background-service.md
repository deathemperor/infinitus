# Running the server in the background

<<<<<<< HEAD
A Linux machine can run the Infinitus server as a service for your user, so it
stays available to your phone, a browser or the desktop app without a terminal
kept open.

## Before you start

The service runs the self-contained server from a release archive. Get it onto
the machine first:

```sh
curl -fsSL https://infinitus.run/install.sh | sh
```

It downloads the newest release's `infinitus-<version>-linux-<arch>.tar.gz`, checks
it against the release's `SHA256SUMS`, unpacks it under `~/.infinitus/runtime`
and links `infinitus` into `~/.local/bin`. It needs only `sh`, `tar`, `curl` or
`wget`, and `sha256sum`; no Node.js. Set `T3CODE_VERSION` to pin a release
(the archives start with the release after 0.5.0-alpha.11), or
`T3CODE_RELEASE_BASE_URL` to download from a mirror.

Without the script, download the archive and `SHA256SUMS` from a
[release](https://github.com/deathemperor/infinitus/releases) yourself, check
it — `sha256sum -c --ignore-missing SHA256SUMS` — and unpack it; the `infinitus`
inside is the server, run as `./infinitus` below.

If the machine is an SSH remote of your desktop app, skip all of this: the
desktop puts the matching server on it by itself.

## Manage the service

Run these on the machine that will host the server:

| Task                                  | Command                       |
| ------------------------------------- | ----------------------------- |
| Set up access from your other devices | `infinitus up`                |
| See how your other devices reach it   | `infinitus status`            |
| Install and start                     | `infinitus service install`   |
| Inspect status and log location       | `infinitus service status`    |
| Update or repair                      | `infinitus service update`    |
| Restart                               | `infinitus service restart`   |
| Stop and remove from startup          | `infinitus service uninstall` |

The service reuses the copy the install script put under
`~/.infinitus/runtime`; a hand-unpacked `./infinitus` downloads that version's
archive there first, so the machine needs to reach the releases (or
`T3CODE_RELEASE_BASE_URL`). Uninstalling the service leaves your projects,
threads and settings under `~/.infinitus/userdata` intact.

`infinitus update` moves a script-installed `infinitus` to the newest release: it downloads
and verifies it, points `infinitus` at it, and asks before restarting a background
service (pass `--yes` from a script; decline and the service keeps running its
current version until `infinitus service restart`; a server you started by hand is
left for you to restart). Pass an exact version to pin one, or `--allow-downgrade` to
move backwards. Install and update use the version of the `infinitus` you run; an
older `infinitus` refuses to replace a newer service unless you add
`--allow-downgrade`. `infinitus uninstall` reverses the install script — the service,
the `infinitus` link, every downloaded version — and keeps `~/.infinitus/userdata`
and `service.env`.

Updating restarts the server. Finish active work first, and wait for any remote
update already in progress.

## Local network access

A new service answers only on this machine. Other devices reach it through
Infinitus Connect, or directly once you choose the local network in `infinitus up` (or run
`infinitus up --lan`, which sets `T3CODE_LAN=true` in `service.env`). It then listens on
your local network and Tailscale addresses, so the desktop and mobile apps on
the same network connect directly instead of through Infinitus Connect. It still does
not answer on public addresses. Anyone on the same network can reach the port,
so a pairing code is all that keeps them out. The hosted web app at app.t3.codes
stays on Infinitus Connect, because browsers block plain HTTP from an HTTPS page.

A service installed before `T3CODE_LAN` existed keeps listening on the local
network. `infinitus status` says so, and `infinitus up --no-lan` turns it off. Any
`T3CODE_HOST` value replaces this setting.

## Configure the service environment

Put custom environment variables in `service.env` under the service's Infinitus home
directory, normally `~/.infinitus/service.env`. This file survives service installation
and updates. For example:
=======
Run Infinitus as a background user service on Linux, macOS, or Windows so your host stays reachable without keeping a terminal open.

## Manage the service

Install the `t3` CLI first ([Command line](./install.md#command-line)), then run these commands on the host machine:

| Task                                    | Command                                                   |
| --------------------------------------- | --------------------------------------------------------- |
| Set up access from other devices        | `t3 up`                                                   |
| Check how other devices reach it        | `t3 status`                                               |
| Install and start (or repair)           | `t3 service install`                                      |
| Check status and log path               | `t3 service status`                                       |
| Update to a newer release               | `t3 update`                                               |
| Restart                                 | `t3 service restart`                                      |
| Stop and remove from startup            | `t3 service uninstall`                                    |
| Remove service, launcher, and downloads | `t3 uninstall` (keeps `~/.t3/userdata` and `service.env`) |

- Pairing codes are never written to logs; run `t3 pair` or `t3 up` on the host to connect a device.
- `t3 update` asks before restarting (pass `--yes` in scripts). Pin a version with `t3 update 0.0.42`, switch tracks with `--channel nightly`, or downgrade with `--allow-downgrade`.

## Local network access

New services bind to localhost only. Run `t3 up --lan` (sets `T3CODE_LAN=true` in `service.env`) to listen on LAN and Tailscale addresses for direct desktop/mobile connections, or `t3 up --no-lan` to disable it. Anyone on that network can reach the port (gated by pairing). `T3CODE_HOST` overrides `T3CODE_LAN`. Hosted `app.t3.codes` always uses Infinitus Connect.

## Configure the service environment

Add `KEY=VALUE` entries to `service.env` in your Infinitus home directory (`~/.t3/service.env` by default). Values are literal (quote spaces or `#`; no shell expansion) and survive installs and updates.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

```dotenv
T3CODE_PORT=3773
T3CODE_HOST=127.0.0.1
```

<<<<<<< HEAD
Use `KEY=VALUE` entries, quoting values that contain spaces or `#`. Values are
literal: shell commands and variable expansion are not evaluated. Entries
override the inherited service environment, except for `PATH`, `T3CODE_HOME`,
`T3_BOOT_SERVICE_UNIT`, and `T3_SERVICE_LAUNCHER_CONTEXT` (including case variants).

Run `infinitus service restart` after changing the file. Changes apply when the service
starts again; switching the server version alone keeps the current values.
For a service installed before env-file support, run `infinitus service install` once
with an up-to-date CLI.
A missing file is ignored; other read failures stop service startup.
If the file contains credentials, restrict access to that file with `chmod 600`
(for the default Infinitus home, `chmod 600 ~/.infinitus/service.env`).

## Platform support

Linux needs systemd user services. Setup enables lingering so the server starts
at boot and keeps running after logout. If this needs administrator permission,
setup prints a recovery command before changing the service.

macOS: the service commands exist, but no macOS server archive is published
yet (the install script says so and stops), so there is nothing to install
them from. Keep the desktop app running on
the Mac instead; it hosts remote clients the same way.
=======
- `PATH`, `T3CODE_HOME`, `T3_BOOT_SERVICE_UNIT`, and `T3_SERVICE_LAUNCHER_CONTEXT` cannot be overridden here.
- Run `t3 service restart` after editing (and `chmod 600 ~/.t3/service.env` if it holds secrets).

## Platform support

- **Linux**: Requires systemd user services with lingering enabled so Infinitus starts at boot and survives logout.
- **macOS**: Starts at login, stops at logout. Keep the Mac logged in and awake for unattended access. If agents can't read Desktop/Documents/Downloads, grant Full Disk Access to the `t3` path in `~/Library/LaunchAgents/com.t3tools.t3code.service.plist`.
- **Windows**: Runs windowless via Task Scheduler (`t3code-<domain>-<user>`) while signed in and auto-restarts on exit. Lock the screen instead of signing out for unattended access.

> Note: Signing out of Infinitus Connect does not stop or uninstall the background service.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## Keep the server responsive under memory pressure (Linux)

<<<<<<< HEAD
`infinitus up` installs the service when you set up Infinitus Connect, but the two are managed
separately. Signing out of Infinitus Connect does not stop or uninstall the service.

## Keep the server responsive when agents use all memory

On Linux, agents already run with lower priority than the server. When they
fill the machine's memory, though, the kernel may still slow down or stop the
server, because only an administrator can reserve memory for it. Run, as your
normal user:
=======
On Linux, agents run at lower priority than the server, but heavy memory use can still trigger the OOM killer. Run as your normal user:
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

```sh
t3 service protect
```

It previews system changes, asks for confirmation and `sudo`, and optionally protects Tailscale and SSH too. Run `t3 service restart` for OOM-killer protection to take effect, or `t3 service protect --undo` to remove it.

## Troubleshooting

<<<<<<< HEAD
Start with `infinitus service status` on the host. It prints the log path and checks
whether the installed service is running, enabled, and allowed to survive
logout.
=======
Run `t3 service status` on the host to see the log path and health checks:
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

| Status                                 | Fix                                                                                                                                               |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `linger-disabled`                      | Run `sudo loginctl enable-linger "$(id -un)"` (or `ssh -t your-server '...'`), then retry setup as your normal user. Never run Infinitus as root. |
| `linger-unavailable`                   | Check `loginctl show-user "$(id -un)" --property=Linger` and verify `systemd-logind`.                                                             |
| `user-manager-unavailable`             | Run `systemctl --user status` in a login session to verify systemd user support.                                                                  |
| `service-disabled` / `service-stopped` | Check the log and `systemctl --user status t3code.service`, then run `t3 service install`.                                                        |
| `restart-pending`                      | Run `t3 service restart` to switch to the newly installed version.                                                                                |

<<<<<<< HEAD
```sh
sudo loginctl enable-linger "$(id -un)"
```

Over SSH, allow sudo to prompt:

```sh
ssh -t your-server 'sudo loginctl enable-linger "$(id -un)"'
```

Then retry service setup as your normal user. Run only the `loginctl` command
with sudo; running the server as root creates a separate installation and
Connect identity. Without administrator access, run `./infinitus serve` in a terminal
and keep that session open.

| Status problem                          | Next step                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `linger-unavailable`                    | Run `loginctl show-user "$(id -un)" --property=Linger` and check that systemd-logind is available.                             |
| `user-manager-unavailable`              | Run `systemctl --user status` in a login session for the service user; check your distribution's systemd user-session support. |
| `service-disabled` or `service-stopped` | Read the log and `systemctl --user status t3code.service`, then use the repair command printed by the server.                  |
| `restart-pending`                       | A newer version is installed but the service still runs the previous one. Run `infinitus service restart`.                     |

For failures after signing in to Infinitus Connect, see
[connection troubleshooting](./t3-connect-troubleshooting.md).
=======
For Infinitus Connect issues, see [Infinitus Connect troubleshooting](./t3-connect-troubleshooting.md).
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## Reclaim database space

Infinitus automatically prunes old internal history while keeping conversations. Older databases that still hold freed space show a **Reclaim** button in **Settings → Maintenance** when at least 1 GiB is reclaimable (pauses the server/agents during repair).

For manually started servers (or CLI use), stop any hand-started server or desktop app and run:

<<<<<<< HEAD
In other cases, such as a server you started by hand, run `infinitus doctor` on the
machine that hosts the environment. It reports the database size and the
space it can reclaim, then asks which repairs to run;
pass `--fix` to run the recommended ones without a prompt (for scripts), or
`--dry-run` to only report. An installed background service for the same data
directory is stopped for the repair and started again afterwards, also when
the repair fails. Quit a server you started by hand, or the desktop app, first:
the repair refuses to touch a database that is in use, and names the server
process that holds it when it can tell. While the repair runs, a server started
for the same data directory, for example by a desktop app connecting over SSH,
is refused until the repair ends. Use `--base-dir` for a different data
directory.

The repair's time grows with the size of the whole database, not only the
space it reclaims, and can exceed an hour on a large database or a slow disk;
`t3 doctor` shows each step as it runs. It rebuilds the database through a
temporary copy, so it needs free space of about twice the data still in use
(the database size minus the reclaimable space): once in the system temporary
directory (on Linux and macOS, `TMPDIR`, or `/var/tmp` when it is not set) and
once next to the database for its write-ahead log.

If you upgraded from a version before 0.1.0, its database (`state.sqlite`) is
still kept next to the current one so you can roll back. `infinitus doctor` offers to
delete it, but never selects that repair for you and `--fix` skips it: once it
is gone, a version before 0.1.0 starts with no threads or settings. It does
not offer to delete it while any project or thread you have not deleted is
missing from the current database, so the old file stays available for
recovery.
=======
```sh
t3 doctor          # Interactive repair (auto-stops/restarts a background service)
t3 doctor --dry-run
t3 doctor --fix    # Non-interactive recommended repairs
```

- Needs free disk space of ~2× active data size (in `TMPDIR`/`/var/tmp` and beside the database). Large databases can take over an hour.
- `t3 doctor` optionally offers to remove the legacy pre-0.1.0 `state.sqlite` backup only when all active projects and threads exist in the current database (`--fix` never deletes it automatically).
>>>>>>> upstream-sync-d878f7b192-upstream-renamed
