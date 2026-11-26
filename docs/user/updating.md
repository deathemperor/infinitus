# Updating

Infinitus clients and servers can run on different machines and must share a compatible orchestration protocol. When a server or provider is behind, the sidebar update button and **Settings → Environments** handle updates.

## Update everything at once

Click the **Update** button at the bottom of the sidebar (web or desktop) to update outdated providers, behind servers, and the desktop app in one step.

- Hover to preview what will update; click while running to view per-machine progress or retry failures.
- Confirmation dialogs show which machines are skipped (offline or manual-only) and how many active threads will pause/resume.
- Choose **Later** on the desktop restart countdown to restart when ready.

## Switch between Stable and Nightly

In the desktop app, change **Settings → About → Update track** to switch connected machines together.

- Moving a background service to an older Stable release requires running `t3 update --channel stable --allow-downgrade` on that host.
- A switch is blocked if the machine's database has schema changes the target track doesn't support yet. macOS desktop apps must switch on that Mac.

## Continue threads after restarts

**Settings → Maintenance → Continue threads after restarts** is enabled by default. After an update, crash, or reboot (once Infinitus starts again), supported active threads automatically resume—and threads waiting on subagents or monitors are woken and notified that background work stopped.

- Threads waiting for your approval/answer/secret—or archived, snoozed, or settled—are not auto-resumed.
- After 3 consecutive crash recoveries of an unfinished turn, the thread waits for your next message.
- Updating from V1? Read [Threads from older Infinitus versions](./thread-migration.md).

## Update a connected server manually

| Situation                           | Action                                                                                                |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Background service / desktop server | Click **Update server** in **Settings → Environments** (desktop hosts relaunch automatically).        |
| Installed `t3` CLI                  | Run `t3 update <version>` on the host (then `t3 service restart` if you declined the restart prompt). |
| `npx` server                        | Stop the server and relaunch with `npx t3@<version>` and your usual flags.                            |
| Package manager (Nix, AUR)          | Update via your package manager.                                                                      |

<<<<<<< HEAD
Updates from the previous orchestration system preserve conversation transcripts but cannot carry
every kind of runtime history forward. Read [Threads from older Infinitus versions](./thread-migration.md)
before continuing an important older thread.

## When versions don't match

A client and server must speak the same orchestration protocol. If they do not, the connection is
refused rather than running half-upgraded:

- An app newer than the server is blocked before connecting, with a notice telling you to update
  Infinitus on the machine named in the notice.
- A server newer than your app refuses the connection with an update message.

Update the side the notice names, then reconnect.

## Update a connected server

The offered action depends on how the server runs:

| Action                     | What to do                                                                                                                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Update server**          | Keep the client open while it installs and reconnects. Supported background services update remotely. For a desktop-hosted server, this also closes and relaunches the desktop app on the host. |
| **Update the desktop app** | Update the desktop app on the machine running the server, then reopen it if needed.                                                                                                             |
| **Copy update command**    | Run the command on the named host to update the detected global npm install or installed `t3` command, then restart the server with your usual options.                                         |
| **Copy relaunch command**  | Stop the command-line server on its host and relaunch with the copied command, keeping your usual subcommand and options. This does not update an installed `t3` command.                       |

For a background service on a Linux host, download and unpack the server
archive of the version shown in the notice (see
[Install](./install.md#headless-server-linux)) and run its `./t3 service update`
on the host. Only that exact version resolves the mismatch. An older service may
need this local update once before it supports remote updates and rollback.

For a foreground server, stop it and start the matching version's `./t3` the
same way you started the old one — add `serve` if you run without a browser,
and keep options such as `--host` or `--tailscale-serve`. See
[Running in the background](./background-service.md) for service management.

## If an update fails

Keep the client open until it reconnects or reports a failure. A failed service
update can roll back to the previous version. If the update still fails:

1. Retry the offered action once.
2. Check that you updated the server's machine, not only the device you are using.
3. For a command-line server, stop it and relaunch the exact version shown in the notice.

Only one server can use an Infinitus home directory at a time. If startup reports that
another server owns it, stop that server before retrying, or use a separate home
directory and pair with the running server.

### macOS app does not reopen after an Alpha update

Updating an older **Infinitus (Alpha)** installation can replace it with
**Infinitus (Beta)** without reopening the app. Open **Infinitus (Beta)** from
Applications, or run:

```sh
open "/Applications/T3 Code (Beta).app"
```

If an old Dock shortcut no longer opens the app, remove it and add the Beta app
from Applications again.

## If the desktop app does not start

If the desktop app's server keeps failing at startup, Infinitus shows a "T3 Code
could not start" window instead of the app. If a newer version is available,
choose **Update** to install it. If not, the window links to the last version
that started on your computer. Download and install it to go back. Use **Copy
details** to include the error in a bug report.

## Registries and proxies

Each server checks Infinitus releases, and providers installed with npm, through
its own npm, so the checks use npm's configured registry, authentication, and
proxy settings. Providers installed with Homebrew or pnpm check through those
tools.
Configure npm on the server's machine. If that registry cannot be reached, the
release shows as unavailable; Infinitus does not try the public registry instead.
Machines without npm check the public npm registry directly.
=======
Each server checks npm/Homebrew/pnpm using its own local registry and proxy settings.
>>>>>>> upstream-sync-986826178c-upstream-renamed

## Update providers

Open **Settings → Providers** and click **Update now** on individual providers or **Update all** across connected environments. Running chats keep using their current CLI until they end; new sessions and model catalogs refresh automatically. (Provider update checks in **Settings → Maintenance** must be enabled to fetch model catalog updates.)

## Mobile updates

- Update connected environments and providers from **Settings → Environments** on mobile.
- Update the mobile app via the App Store or Google Play (background over-the-air updates apply on next app switch and preserve drafts/queued messages).

## Troubleshooting

<<<<<<< HEAD
The phone app is not on a store: it is installed from a build. Update it by
installing a newer build the same way. It saves drafts and queued messages
before it restarts.
=======
- **Version mismatch**: Update whichever side (app or server) the connection notice names.
- **Failed update**: Retry once; confirm you updated the host machine (not just the client) and that only one server owns the Infinitus home directory.
- **macOS Alpha → Beta**: Open `/Applications/T3 Code (Beta).app` manually and re-pin it to the Dock.
- **Desktop won't start**: Use the recovery window's **Update** button, install the linked last-working version, or **Copy details** for a bug report.
>>>>>>> upstream-sync-986826178c-upstream-renamed
