# Running the server in the background

A Linux machine can run the Infinitus server as a service for your user, so it
stays available to your phone, a browser or the desktop app without a terminal
kept open.

## Before you start

The service runs the self-contained server from a release archive. Get it onto
the machine first:

1. From a [release](https://github.com/deathemperor/infinitus/releases) cut
   after 0.5.0-alpha.11, download `t3-<version>-linux-x64.tar.gz` or
   `t3-<version>-linux-arm64.tar.gz` for the machine's architecture, and
   `SHA256SUMS` from the same release.
2. Check it — `sha256sum -c --ignore-missing SHA256SUMS` — and unpack it:
   `tar -xzf t3-<version>-linux-x64.tar.gz`.
3. The `t3` executable inside is the server. It needs no Node.js.

There is no install script for Infinitus yet; the `curl … | sh` and
`npx t3` paths you may know from T3 Code install upstream's product, not this
one.

If the machine is an SSH remote of your desktop app, skip all of this: the
desktop puts the matching server on it by itself.

## Manage the service

Run these on the machine that will host the server, from the directory you
unpacked into:

| Task                            | Command                  |
| ------------------------------- | ------------------------ |
| Install and start               | `./t3 service install`   |
| Inspect status and log location | `./t3 service status`    |
| Update or repair                | `./t3 service update`    |
| Stop and remove from startup    | `./t3 service uninstall` |

Installing downloads that version's archive once more from the release into
`~/.infinitus/runtime` (set `T3CODE_RELEASE_BASE_URL` to take it from a
mirror), so the machine needs to reach the releases and you can delete the
unpacked directory afterwards. Uninstalling the service
leaves your projects, threads and settings under `~/.infinitus/userdata`
intact.

Install and update use the version of the `t3` you run. To move the service to
a newer release, download and unpack that release's archive the same way and
run its `./t3 service update`. An older `t3` refuses to replace a newer service
unless you add `--allow-downgrade`.

Updating restarts the server. Finish active work first, and wait for any remote
update already in progress.

## Platform support

Linux needs systemd user services. Setup enables lingering so the server starts
at boot and keeps running after logout. If this needs administrator permission,
setup prints a recovery command before changing the service.

macOS: the service commands exist, but no macOS server archive is published
yet, so there is nothing to install them from. Keep the desktop app running on
the Mac instead; it hosts remote clients the same way.

Windows background services are not supported.

T3 Connect can offer service installation during setup, but the two are managed
separately. Signing out of T3 Connect does not stop or uninstall the service.

## Troubleshooting

Start with `t3 service status` on the host. It prints the log path and checks
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
Connect identity. Without administrator access, run `./t3 serve` in a terminal
and keep that session open.

| Status problem                          | Next step                                                                                                                      |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `linger-unavailable`                    | Run `loginctl show-user "$(id -un)" --property=Linger` and check that systemd-logind is available.                             |
| `user-manager-unavailable`              | Run `systemctl --user status` in a login session for the service user; check your distribution's systemd user-session support. |
| `service-disabled` or `service-stopped` | Read the log and `systemctl --user status t3code.service`, then use the repair command printed by the server.                  |

For failures after signing in to T3 Connect, see
[connection troubleshooting](./remote-access.md#t3-connect-troubleshooting).
