# Running the server in the background

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

| Task                            | Command                       |
| ------------------------------- | ----------------------------- |
| Install and start               | `infinitus service install`   |
| Inspect status and log location | `infinitus service status`    |
| Update or repair                | `infinitus service update`    |
| Stop and remove from startup    | `infinitus service uninstall` |

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
the `infinitus` link, every downloaded version — and keeps `~/.infinitus/userdata`.

<<<<<<< HEAD
Updating restarts the server. Finish active work first, and wait for any remote
update already in progress.
=======
Pass an exact version (`t3 update 0.0.42`) to pin one, `--channel nightly` to
switch trains, or `--allow-downgrade` to move backwards. `preview` is a
maintainers' test train: its builds can be broken and are never offered as
updates, so the installer and `t3 update` ask for confirmation before
installing one.

`t3 uninstall` removes the background service, the `t3` launcher, and the
downloaded versions after showing you the list and asking once. Your projects,
threads, and settings under `~/.t3/userdata` are kept, along with `service.env`
under Infinitus home. Pass `--yes` from a script.

## Configure the service environment

Put custom environment variables in `service.env` under the service's Infinitus home
directory, normally `~/.t3/service.env`. This file survives service installation
and updates. For example:

```dotenv
T3CODE_PORT=3773
T3CODE_HOST=127.0.0.1
```

Use `KEY=VALUE` entries, quoting values that contain spaces or `#`. Values are
literal: shell commands and variable expansion are not evaluated. Entries
override the inherited service environment, except for `PATH`, `T3CODE_HOME`,
`T3_BOOT_SERVICE_UNIT`, and `T3_SERVICE_LAUNCHER_CONTEXT` (including case variants).

Run `t3 service restart` after changing the file. Changes apply when the service
starts again; switching the server version alone keeps the current values.
For a service installed before env-file support, run `t3 service install` once
with an up-to-date CLI.
A missing file is ignored; other read failures stop service startup.
If the file contains credentials, restrict access to that file with `chmod 600`
(for the default Infinitus home, `chmod 600 ~/.t3/service.env`).
>>>>>>> upstream-sync-1dfb57287-upstream-renamed

## Platform support

Linux needs systemd user services. Setup enables lingering so the server starts
at boot and keeps running after logout. If this needs administrator permission,
setup prints a recovery command before changing the service.

macOS: the service commands exist, but no macOS server archive is published
yet (the install script says so and stops), so there is nothing to install
them from. Keep the desktop app running on
the Mac instead; it hosts remote clients the same way.

Windows background services are not supported.

Infinitus Connect can offer service installation during setup, but the two are managed
separately. Signing out of Infinitus Connect does not stop or uninstall the service.

## Troubleshooting

Start with `infinitus service status` on the host. It prints the log path and checks
whether the installed service is running, enabled, and allowed to survive
logout.

If it stops when your SSH session closes, check for `linger-disabled`. An
administrator can enable lingering with:

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
<<<<<<< HEAD
[connection troubleshooting](./remote-access.md#infinitus-connect-troubleshooting).
=======
[connection troubleshooting](./t3-connect-troubleshooting.md).

## Reclaim database space

Infinitus removes superseded internal history on its own while it runs; your
conversations are kept. Databases created before this shrank automatically
still hold the freed space on disk until a one-time offline repair returns it
and turns on automatic shrinking. Settings > Storage (web and desktop) or
Settings > Maintenance (mobile) suggests the repair when at least 1 GiB can be
reclaimed.

Run `t3 doctor` on the machine that hosts the environment. It reports the
database size and the space it can reclaim, then asks which repairs to run;
pass `--fix` to run the recommended ones without a prompt (for scripts), or
`--dry-run` to only report. An installed background service for the same data
directory is stopped for the repair and started again afterwards, also when
the repair fails. Quit a server you started by hand, or the desktop app, first:
the repair refuses to touch a database that is in use. Use `--base-dir` for a
different data directory.

The repair can take several minutes on a large database. It rebuilds the
database through a temporary copy, so it needs free space of about the
database's size twice over: once in the system temporary directory (`TMPDIR`
or `/tmp` on Linux and macOS) and once next to the database for its
write-ahead log.

If you upgraded from a version before 0.1.0, its database (`state.sqlite`) is
still kept next to the current one so you can roll back. `t3 doctor` offers to
delete it, but never selects that repair for you and `--fix` skips it: once it
is gone, a version before 0.1.0 starts with no threads or settings.
>>>>>>> upstream-sync-1dfb57287-upstream-renamed
