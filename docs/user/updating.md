<<<<<<< HEAD
# Updating
=======
# Updating Infinitus
>>>>>>> upstream-sync-7445aa733-upstream-renamed

The app you use and the server running your agents can be on different machines.
When a server is behind your web or desktop app, an update notice appears in the
conversation and **Settings → Connections**. Update the machine named in that
notice.

## Before you update

Server updates restart the connection and can interrupt active agents and
terminal commands. Saved threads, settings, and project files remain.

**Settings → General → Continue threads after restarts** is off by default.
Enable it to resume supported active threads after an update, crash, or machine
restart. Changes are saved to connected environments that support this setting;
update older servers first. If a supported environment was offline or has a
different value, use **Apply to all** in Settings after it connects.
Infinitus must start again on that machine;
the setting does not enable automatic startup. Terminal commands may still be
interrupted, and threads without saved provider resume state need a new message.
If you previously enabled continuation for updates, enable this setting once
to allow recovery without a connected client.

## Update a connected server

The offered action depends on how the server runs:

| Action                     | What to do                                                                                                                                                                                      |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Update server**          | Keep the client open while it installs and reconnects. Supported background services update remotely. For a desktop-hosted server, this also closes and relaunches the desktop app on the host. |
| **Update the desktop app** | Update the desktop app on the machine running the server, then reopen it if needed.                                                                                                             |
| **Copy update command**    | Stop the command-line server on its host and relaunch with the copied command, keeping your usual startup options.                                                                              |

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

## Mobile updates

The phone app is not on a store: it is installed from a build. Update it by
installing a newer build the same way. It saves drafts and queued messages
before it restarts.
