# Infinitus Connect troubleshooting

An Infinitus Connect connection passes through four stages:

1. **This device** reaches Infinitus Connect over the internet.
2. **Infinitus Connect** verifies your sign-in and host link.
3. **The host's tunnel** (`cloudflared`) forwards the request to the host.
4. **Infinitus on the host** answers.

<<<<<<< HEAD
When a connection fails, open **Settings > Environments**, find the environment,
and select **Details**. The first part marked as failed is the cause. Find its
section below.

To see the host's side, run `infinitus connect status` on the host, or open
**Settings > Sharing & access** on the host. Both check the host's Infinitus Connect
address from the host, and say why it fails. `infinitus connect` runs the same check
when it finishes setup. This check cannot test another device's network. For a
problem on one device, use **Details** on that device.
=======
When a connection fails, open **Settings → Environments**, select the environment, and choose **Details**—the first failed stage identifies the cause below. On the host itself, run `t3 connect status` or check **Settings → Sharing & access**.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## The host's tunnel is offline

Infinitus Connect could not reach the host's tunnel (host is asleep/offline, Infinitus isn't running, or outbound port 7844 is blocked).

<<<<<<< HEAD
- The host is asleep, turned off, or offline.
- Infinitus is not running on the host.
- The host's network blocks the tunnel. See
  [Port 7844 is blocked on the host](#port-7844-is-blocked-on-the-host).

Fix:

1. Make sure the host is awake and Infinitus runs on it.
2. On the host, run `infinitus connect status`. It names the problem on the host's side.
3. If the host was offline for a long time, Infinitus Connect removes its tunnel. Start
   Infinitus on the host and update it to the latest version. It gets a new tunnel.
=======
1. Confirm the host is awake and running Infinitus.
2. Run `t3 connect status` on the host.
3. If the host was offline for 7+ days on an older version, start and update Infinitus on the host to recreate its tunnel.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## Port 7844 is blocked on the host

`cloudflared` connects outbound to Cloudflare on **TCP and UDP port 7844** (normal web traffic still works when 7844 is blocked).

- **Tailscale exit node**: Run `tailscale set --exit-node=` on the host or allow outbound 7844 on the exit node.
- **Work VPN / firewall**: Allow outbound TCP/UDP 7844, or bypass Infinitus Connect by adding a direct Tailscale route ([Reach one machine several ways](./remote-access.md#reach-one-machine-several-ways)).

## The tunnel works, but Infinitus does not answer

The tunnel is up, but Infinitus didn't respond on `127.0.0.1` (crashed, starting up, port changed, or `T3CODE_HOST` bound only a non-loopback IP).

<<<<<<< HEAD
- Infinitus on the host stopped, crashed, or is still starting.
- Infinitus restarted on a different port, for example after an update, and the
  tunnel still points at the old port.
- The server binds only one network address with `T3CODE_HOST`. The tunnel
  sends requests to `127.0.0.1`, so the server must also listen there.

Fix: restart Infinitus on the host. For the background service, run
`infinitus service restart`. Then run `infinitus connect status` on the host.
=======
Restart Infinitus on the host (`t3 service restart` for a background service) and run `t3 connect status`.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## The Infinitus Connect address does not resolve or answer

The host's Infinitus Connect address failed DNS, TLS, connection, or timed out.

<<<<<<< HEAD
Fix:

1. Make sure the host is awake and online.
2. On the host, run `infinitus connect status`.
3. If the check fails only on the host, check the host's DNS, VPN, or proxy.
   If it says the host's network has an old cached answer, wait: it usually
   clears within about 30 minutes.
4. If it says the address no longer points to this machine's tunnel, the
   environment was likely removed from Infinitus Connect. Link it again: on a desktop
   host, turn **Infinitus Connect** off and on in **Settings > Sharing & access**. On a
   command-line host, run `t3 connect link`, then restart Infinitus.
=======
1. Confirm the host is online and run `t3 connect status`.
2. If only the host fails, check DNS/VPN/proxy (stale DNS caches clear in ~30 minutes).
3. If the address no longer points to this host, re-link it: toggle **Infinitus Connect** off and on in **Settings → Sharing & access**, or run `t3 connect link` and restart the server.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## This device can't reach Infinitus Connect

The issue is on the client device's network:

1. Check for captive portals or dead Wi-Fi.
2. Temporarily disable VPNs, firewalls, ad blockers, or DNS filters (on iPhone, test turning off Wi-Fi **Connectivity Assist**).
3. Try another network or add a direct Tailscale route ([Reach one machine several ways](./remote-access.md#reach-one-machine-several-ways)).

## Sign-in, account, or link problems

<<<<<<< HEAD
This device's Infinitus Connect sign-in is not ready yet, or Infinitus Connect does not have
an active link between your account and the host.

- **The host is linked to a different account.** Sign in to the same Infinitus Connect
  account on this device and on the host. On the host, run `infinitus connect logout`,
  then `infinitus connect`.
- **Infinitus Connect is off on the host, or the host only publishes agent activity.**
  On the host, open **Settings > Sharing & access** and turn **Infinitus Connect** on, or
  run `infinitus connect`.
- **The host was linked, but the server did not apply the link yet.** Restart
  the server on the host: quit and reopen the Infinitus desktop app, run
  `infinitus service restart`, or stop `infinitus serve` and run it again.
- **This device's sign-in expired, or the host no longer accepts this
  device.** Sign out of Infinitus Connect and sign in again.
- **This device is still loading its Infinitus Connect sign-in.** Wait a moment;
  Infinitus retries on its own. If it keeps waiting, reload or restart Infinitus on
  this device.
- **The host is waiting for you to approve this device.** The host requires
  approval for new devices. Approve the code this device shows from a device
  that is already connected, or run `t3 auth connect-device approve <code>` on
  the host. See [Approve new devices](./remote-access.md#approve-new-devices).
- **Your account reached its tunnel limit.** Remove an environment you do not
  use from your Infinitus account's Infinitus Connect page, or
  [link a paid T3 Chat account](./remote-access.md#more-machines-with-t3-chat)
  for a higher limit. Then restart Infinitus on the host.
=======
- **Different account**: Sign in to the same Infinitus Connect account on both sides (on host: `t3 connect logout && t3 connect`).
- **Infinitus Connect disabled on host**: Turn on **Settings → Sharing & access → Infinitus Connect** or run `t3 connect`.
- **Link not yet applied**: Restart Infinitus on the host (`t3 service restart` or restart desktop app).
- **Expired session**: Sign out of Infinitus Connect and sign back in.
- **Waiting for device approval**: Approve the displayed code from an existing device or run `t3 auth connect-device approve <code>` on the host ([Approve new devices](./remote-access.md#approve-new-devices)).
- **Machine limit reached**: Deregister an unused host or [link a paid T3 Chat account](./remote-access.md#more-machines-with-t3-chat), then restart the host.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## The clock is off

Infinitus Connect uses short-lived signed proofs. Enable automatic date and time on both the host and client device, then retry.

## The host runs an older Infinitus

Update Infinitus on the host machine ([Updating Infinitus](./updating.md)).

## Infinitus Connect returned an error

<<<<<<< HEAD
| Error                                                     | Fix                                                                                                                                                                                                    |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `environment_link_limit_exceeded` or managed tunnel limit | Remove an unused environment or link a paid T3 Chat account, then restart Infinitus on the host.                                                                                                       |
| `auth_invalid` or `invalid_bearer`                        | Run `infinitus connect login`. If credentials were revoked, run `infinitus connect logout`, then `infinitus connect` again. Restart the server after signing in.                                       |
| Expired or invalid link proof                             | Check the host's date and time, update Infinitus, then restart it.                                                                                                                                     |
| HTTP 403 without a recognized error                       | If the host requires approval for new devices, update Infinitus on this device and approve it. Otherwise check relay access, proxies, and firewall rules. Keep any Cloudflare Ray ID for a bug report. |
| HTTP 408, 429, or 5xx                                     | Wait a few minutes. Infinitus retries temporary failures on its own.                                                                                                                                   |

After you fix a permanent rejection, restart the host's server with
`infinitus service restart`. For a foreground server, stop it and run `infinitus serve` again.

If Infinitus on the host disappears when SSH closes, see
[background-service troubleshooting](./background-service.md#troubleshooting).
=======
| Error                                            | Fix                                                                                                                           |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- |
| `environment_link_limit_exceeded` / tunnel limit | Deregister an unused host or link a paid T3 Chat account, then restart the host.                                              |
| `auth_invalid` / `invalid_bearer`                | Run `t3 connect login` (or `t3 connect logout && t3 connect`), then restart the server.                                       |
| Expired or invalid link proof                    | Sync system clock, update Infinitus, and restart.                                                                             |
| HTTP 403 (unrecognized)                          | If device approval is on, update the client and approve it; otherwise check proxies/firewalls and save any Cloudflare Ray ID. |
| HTTP 408, 429, or 5xx                            | Temporary—wait a few minutes for automatic retry.                                                                             |

After fixing a permanent error, restart the host (`t3 service restart` or restart `t3 serve`). If Infinitus stops when SSH disconnects, see [background-service troubleshooting](./background-service.md#troubleshooting).
>>>>>>> upstream-sync-d878f7b192-upstream-renamed

## Report a problem

Open an issue on [GitHub](https://github.com/pingdotgg/t3code/issues) with:

<<<<<<< HEAD
- The text from **Copy diagnostics** in the environment's **Details**.
- The output of `infinitus connect status` on the host.
- The trace ID, if one is shown.
- If the tunnel dropped earlier, the host's tunnel log, `relay-client.ndjson`
  in the logs folder (`~/.t3/userdata/logs` by default). It records when the
  tunnel connected, warned, exited, and restarted, with the tunnel token
  removed.
=======
- **Copy diagnostics** from the environment's **Details**
- Output of `t3 connect status` on the host
- Trace ID (if shown)
- `~/.t3/userdata/logs/relay-client.ndjson` (tunnel tokens are already stripped)
>>>>>>> upstream-sync-d878f7b192-upstream-renamed
