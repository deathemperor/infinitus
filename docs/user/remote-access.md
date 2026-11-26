# Remote access

Drive Infinitus from your phone, browser (`app.t3.codes`), or another desktop app while your agents run on a host computer or server. The host must stay awake and running while you work.

## Infinitus Connect (recommended)

Infinitus Connect links your host to your other devices without router port-forwarding.

<<<<<<< HEAD
For a Linux host without the desktop app, run the unpacked server archive's
`infinitus` (see [Install](./install.md#headless-server-linux)):

```bash
./infinitus up
```

It asks how your other devices reach the machine: Infinitus Connect, the local network,
or both. Choose Infinitus Connect and follow the sign-in instructions. It then runs
Infinitus as a [background service](./background-service.md).
`./infinitus connect` is the same as `./infinitus up --connect`. Run `./infinitus up`
again to change your choice, and `./infinitus status` to see it. Every `infinitus` command
on this page is that executable; a Mac host runs the desktop app instead and does all
of this from **Settings → Sharing & access**.

On your other device, sign in to the same Infinitus Connect account and choose the
environment. On the app.t3.codes home page with no computer added yet, signing
in adds compatible computers linked to your account. Over SSH, the CLI prints a
browser link and a short code. Open the link on any device, confirm the code
matches, and approve. The CLI continues on its own, so you do not need to forward
an OAuth callback port.

Infinitus Connect renews access credentials when needed without disconnecting a healthy
connection. Pull request diffs and provider settings keep working after the
previous credential expires. A failed renewal affects that request; it does not
disconnect an otherwise healthy conversation.

### Approve new devices

By default, any device signed in to your Infinitus Connect account can open a linked
machine. To require approval instead, turn on **Require approval for new
devices** with the Infinitus Connect settings in **Settings → Sharing & access** on the
host, or when you first set up Infinitus Connect. Then someone who takes over your Infinitus
Connect account cannot reach the machine from a new device without your
approval. Review the devices that are already approved, described below.

A new device waits and shows a code such as `K7QM-2XFD`. Approve it from a
device that is already connected, using the prompt or **Settings → Sharing &
access**. Check that the code matches the one on the waiting device. On a
headless host, run `t3 auth connect-device list` and then
`t3 auth connect-device approve K7QM-2XFD`. A request expires after 10 minutes,
and the device asks again when it retries. Deny keeps that device out until its
request expires.

Each device is approved once. Revoke it from **Infinitus Connect devices** in the same
settings page, or with `t3 auth connect-device revoke <code>`. With approval on,
it has to ask again. With approval off, it can connect again on its own, so
revoking in the app offers to turn approval on first. Devices that connected through Infinitus Connect while approval was off stay
approved and appear in that list for you to review. A device that has not
connected since you updated Infinitus asks for approval like a new one. Older apps
cannot show the code, so update them before you turn approval on.

### Scripts and agents

`./infinitus up` asks nothing when you name a choice: `--connect`, `--lan`, or their
`--no-` forms. Choices you do not name keep their settings, and `--yes` takes
the defaults. Without a terminal:

- Infinitus Connect sign-in prints a URL and a code. Approve it on any device.
- A needed restart runs without asking, and stops running agent turns.
- With nothing set up and no choice named, `./infinitus up` stops and names the flags.

`./infinitus status --json` prints the settings. `./infinitus up --help` lists every flag with
examples.
=======
- **Desktop host**: Open **Settings → Sharing & access**, sign in, and turn on **Infinitus Connect** (note: closing the desktop app's last window stops its local server—use the [background service](./background-service.md) for unattended access).
- **CLI / headless host**: Run `t3 up` (or `t3 connect` / `t3 up --connect --lan --yes` for non-interactive scripts) and complete the printed sign-in link on any device. Check status with `t3 status [--json]`.
- **Other devices**: Sign in to the same Infinitus Connect account and pick the environment.

### Approve new devices

By default, any device signed into your Infinitus Connect account can connect. Turn on **Require approval for new devices** in **Settings → Sharing & access** on the host so new devices must present a short code (valid 10 minutes) that you approve from an existing device or via `t3 auth connect-device approve <code>`. Revoke devices anytime in **Settings → Sharing & access** or `t3 auth connect-device revoke <code>`.
>>>>>>> upstream-sync-986826178c-upstream-renamed

### More machines with T3 Chat

Free Infinitus Connect accounts can link up to **3 host machines** (phones and browsers don't count). Link a paid T3 Chat account from your account menu → **T3 Chat → Link T3 Chat** to raise the limit to **10** (Pro) or **100** (Premier).

## Pair over a LAN or private network

<<<<<<< HEAD
Use direct pairing when the other device can reach the host's network address.

On a desktop host, open **Settings → Sharing & access**, enable **Network access**,
then create a pairing link using an address the other device can reach. Changing
network access restarts the desktop app. You can turn it off in the same place.

For a command-line host, choose the local network in `./infinitus up`, or run:

```bash
./infinitus up --lan
```

For a server in a terminal, run `./infinitus serve --lan`. Either way, Infinitus then
accepts connections from your local network and tailnet, so a pairing code is
all that keeps other devices on them out.

If a server is already running, generate a fresh link without restarting it:

```bash
./infinitus pair
```

Scan the QR code on your phone or paste the pairing URL into **Add environment**
in the receiving app. Connection settings are under **Settings → Environments**
on web and desktop and **Settings → Environments** on mobile. A loopback address
such as `127.0.0.1` reaches only the device opening the link.

On a computer with the desktop app, you can open the printed `t3code://pair`
app link instead. The desktop app asks you to confirm the server address, then
adds it.

If your HTTPS endpoint uses a certificate from your own certificate authority,
install that CA on Android as a **CA certificate** in its security settings; the
Android app then trusts it.

Pairing authorizes that device for future connections. Use a fresh one-time link
for each new device; you do not need the original token to reconnect. A device
stays signed in while you keep using it, until you revoke it in **Settings →
Sharing & access** on the host. One unused for 30 days, or paired with a host
older than this release, has to pair again. Links
created in Settings can only be copied from the client that created them while
its Sharing & access page stays open. If you leave or reload that page, create
another link to share.

### Reach one machine several ways

A machine can have more than one route: LAN, Tailscale, another VPN, a public
URL, SSH, or Infinitus Connect. Tailscale shares its `100.64.0.0/10` address range with
other VPNs such as Cloudflare WARP, so an address in that range shows as VPN
unless the machine confirms it is on Tailscale. To add a route, choose **Add
route** in the machine's route list, or next to it in the Infinitus Connect list.
A pairing link for a saved machine is refused when it comes from an address
that machine does not have yet; add that address with **Add route** instead.
Pairing again over an address the machine already has still works. A new route
is placed by speed, in that order, and you can reorder routes at any time.

While connected through Infinitus Connect or a paired address, Infinitus also learns the
machine's current LAN and Tailscale addresses and adds them as routes, so
pairing once through Infinitus Connect is enough to use the LAN at home. When the
machine's LAN address changes, for example after it joins another Wi-Fi network,
the learned route follows it. The machine must allow network access for its LAN
address to be learned: **Network access** in the desktop app, or the
[local network](./background-service.md#local-network-access) choice in `./infinitus up`.
You can reorder a learned route, but not remove it; it
goes away with the route it was learned through, or when the machine stops
reporting that address.

Infinitus connects over the first route that answers. Away from home, a LAN
address that does not answer is checked briefly and skipped. It is only tried
again, after the other routes, if none of them connect. While connected over a
later route, Infinitus checks the earlier ones when your network changes, when you
return to the app, and every minute, and moves back as soon as one works. A
route whose machine refused this device's sign-in is marked **Sign-in
refused**; pair that address again with **Add route** to use it.

On web and desktop, select the route count under the machine's name in
**Settings → Environments** to see its routes. Drag a route to change the order,
or remove it. On mobile, open the machine under **Settings → Environments** and
choose **Edit**. Signing out of Infinitus Connect removes only that route; a machine
you can still reach another way stays saved.

Open **Permissions** next to **Routes** in web or desktop, or **Your permissions**
in the mobile route details, to see what your current connection can do on that
environment. For a remote environment, this is in its route details. Permissions
shown there apply only to the route marked **In use**; other routes are not
checked. Direct pairing and Infinitus Connect have separate sessions and may grant
different permissions.

### Balance new threads across machines

Auto balance is off by default. On web and desktop, enable it in
**Settings → Environments → Load balancing** to automatically choose a machine for
new threads in projects grouped across connected environments. The section
appears once two or more machines are switched on.
Each machine starts at **Normal**. Choose **Prefer** to favor it when it has CPU and
memory available, **Less often** to reduce its share, or **Manual only** to exclude
it from automatic selection. These are preferences, not fixed traffic percentages.
Preferences are saved separately in each client.

The composer checks eligible machines when choosing a draft's environment, then keeps
that choice stable. Choose **Auto balance** again to check current resources, or choose
a specific machine to override it. Choosing a branch or worktree also keeps the draft
on that machine. Existing threads stay where they started. If resource checks are
unavailable or all eligible machines are full, choose a machine manually to continue.
Mobile keeps its manual environment selection.
=======
- **Desktop host**: Enable **Settings → Sharing & access → Network access** (restarts desktop) and create a one-time pairing link.
- **CLI host**: Run `t3 up --lan` (background service) or `t3 serve --lan` (foreground), then run `t3 pair` to generate a QR code / pairing URL (`t3code://pair` opens directly in the desktop app).
- **Hosted web app (`app.t3.codes`)**: Requires an HTTPS endpoint (Infinitus Connect or Tailscale HTTPS). For plain HTTP on a LAN, open the direct pairing URL in a local browser or pair from the desktop/mobile app. For custom CAs on Android, install the CA certificate in Android security settings.
- **Session lifetime**: Paired devices stay signed in while active; sessions unused for 30 days must re-pair.

### Reach one machine several ways

A host can have multiple routes (LAN, Tailscale, VPN, public URL, SSH, Infinitus Connect). Infinitus automatically learns LAN and Tailscale routes when network access is enabled, connects over the fastest working route, and switches back to higher-priority routes when you return home. Reorder or add routes in **Settings → Environments** (**Add route**).
>>>>>>> upstream-sync-986826178c-upstream-renamed

### Tailscale HTTPS

Join both devices to a tailnet with [MagicDNS and HTTPS certificates](https://tailscale.com/docs/how-to/set-up-https-certificates) enabled (on Linux, grant [operator permission](https://tailscale.com/docs/reference/troubleshooting/linux/linux-operator-permission)).

- **Desktop**: Enable **Settings → Sharing & access → Tailscale HTTPS**.
- **CLI**: Run `t3 serve --tailscale-serve` or `t3 pair --tailscale` (use `--tailscale-serve-port` if 443 is taken; remove with `tailscale serve --https=443 --set-path=/ off`).

### Balance new threads across machines

<<<<<<< HEAD
```bash
./infinitus serve --tailscale-serve
```

For an already-running server:

```bash
./infinitus pair --tailscale
```

The pairing link uses an address such as `https://machine.tailnet.ts.net/`.
The mapping created by `pair --tailscale` persists across restarts. Remove its
default-port mapping with:

```bash
tailscale serve --https=443 --set-path=/ off
```

If that port is already in use, choose another with
`--tailscale-serve-port`. See `./infinitus pair --help` for other pairing options.

### Web app

Infinitus has no hosted web app; the web app is the one your server serves, at
the pairing link's address. Open the link in a browser that can reach it, or
pair from the desktop app. On mobile, an IP address entered without a scheme
uses HTTP, so include `https://` when your server uses HTTPS.

## Desktop-managed SSH

In the desktop app, open **Settings → Environments → Add environment**, choose
**SSH**, and enter a host or SSH alias such as `user@example.com`. Infinitus
downloads the server of its own version onto the host (it needs `curl` or
`wget` and `tar` there, and a way to reach the releases), starts or reuses it,
and opens the port forward for you. Projects, provider credentials, and agent
work stay on the remote machine, which needs the
[provider setup](./install.md#providers) but no Node.js.

The remote host must be Linux: no macOS server build is published yet, so a
Mac cannot be added this way. A nightly desktop build ships no server archive
and cannot set up a remote either.

Infinitus cannot answer a second sign-in prompt such as a Duo code. On macOS and
Linux it can reuse a connection you signed in to in a terminal instead: turn on
connection sharing for the host in `~/.ssh/config`, run `ssh <alias>`, then
connect. When that connection closes, sign in again in a terminal and retry.

```sshconfig
Host <alias>
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 8h
```

If SSH reconnecting fails after an app update, retry the launch once. Removing
the connection stops a server that Infinitus launched; a server that was already
running is left alone.

Each desktop app keeps one session on the host for its SSH connection and reuses
it when it reconnects. Revoke sessions you no longer use in **Settings →
Sharing & access** on the host, or on a headless host with `infinitus auth session list` and
`infinitus auth session revoke <id>`. A desktop that can still sign in over SSH pairs
again on its next connect.

For Antigravity's Google callback on a remote host, see
[remote sign-in](./providers-antigravity.md#sign-in-from-a-remote-device).
=======
On web and desktop with 2+ connected machines, enable **Settings → Environments → Load balancing** (per client) to auto-select a host for new threads in shared projects. Set each machine to **Prefer**, **Normal**, **Less often**, or **Manual only**.

## Desktop-managed SSH

In the desktop app, open **Settings → Environments → Add environment → SSH** and enter a host or SSH alias (e.g. `user@example.com`). Infinitus downloads its runtime to `~/.t3/runtime` on the Linux or Apple Silicon macOS host, starts or reuses a server, and manages port forwarding automatically.

- Provider CLIs must be on a non-interactive login shell's `PATH` (check with `ssh user@example.com 'sh -lc "command -v claude codex"'`).
- For 2FA/Duo hosts on macOS/Linux, enable SSH `ControlMaster` in `~/.ssh/config` and open a terminal SSH session first.
- Revoke unused SSH sessions in **Settings → Sharing & access** or `t3 auth session revoke <id>`.
>>>>>>> upstream-sync-986826178c-upstream-renamed

## Browser on a remote environment

Browser tabs belong to the host environment so you and your agents share them from any device.

- **Streaming & local loading**: Web and mobile stream tabs from the host. In the desktop app, tabs you open for a remote environment load locally while routing `localhost` requests to the host over the **preview tunnel** (so element picker and annotations work locally).
- **Port forwarding (desktop)**: Forward any remote host port to your local `localhost` via the thread's **Servers** list or **Forwarded ports** in the command palette (`Cmd/Ctrl-click` forwards and opens in your browser).
- **Open on this device (mobile)**: Tap **Open on this device** on a streamed `localhost` tab or long-press a `localhost` link in chat for native touch scrolling.
- **Disable preview tunnel**: Turn off **Settings → Sharing & access → Preview tunnel** on the host (or via [managed policy](./managed-policy.md#other-capabilities)) to disable port forwarding and **Open on this device** (streamed tabs continue working).
- **Take control**: Click **Take control** before typing into an agent's tab, and release control when done.
- **Local servers**: Infinitus lists listening ports from your terminals and agents as `http://localhost:<port>` (set a script's **Preview URL** for HTTPS or subpaths). Disable discovery with `T3CODE_PORT_DISCOVERY=0`.

### Browser host setup

The first server browser tab downloads ~120 MB headless Chromium (shared with [HTML renders](./html-renders.md)). On Ubuntu 23.10+ or minimal Linux containers, run the one-time setup command on the host:

```sh
sudo t3 browser setup
```

This installs an AppArmor profile for Chrome's sandbox plus missing libraries and fonts. Never run the Infinitus server as root (Chrome's sandbox rejects root); if sandboxing is impossible on your host, set `T3CODE_SERVER_BROWSER_SANDBOX=0` in the server environment and restart.

## Link another environment

Link two Infinitus machines (beta) so agents on one can launch, message, delegate to, and manage threads on the other.

1. Enable **Settings → Labs → Linked environments** on **both** machines (or `"linkedEnvironmentsEnabled": true` in `userdata/settings.json`).
2. On the source machine, open **Settings → Environments → Linked environments → Link** (or drag from one machine's `+` to another on the Environments map, or run `t3 environment link <address> --pairing-code <code> --access <mode>`). Use **Link several…** or `--from <file>` for batch linking.
3. Links are one-way (tick **Also link … back** for two-way) and do not chain. Links expire after 30 days of inactivity and can be revoked in **Settings → Sharing & access** or **Forget**.

- **Access boundary**: Agents never get more permissions on the target than the link's access level or their own thread mode. Below Full access, linked agents can only modify threads they started and skip project setup scripts.
- **Delegation**: Agents can target a linked machine with `delegate_task`, or ask you to link an unlinked machine via an in-thread approval card.

### Read a linked machine's threads

Open a delegated task or thread link on a linked machine to follow it live (read-only) in the right panel without pairing your client directly. Click **Connect to interact** to pair and take action (one-click if the link has Full access and you can manage access). Files, images, and HTML renders stay on the remote machine until you connect directly.

## Manage or revoke access

<<<<<<< HEAD
On the host, **Settings → Sharing & access** lets authorized administrators create
pairing links and revoke client sessions. Revoking an unused link prevents new
pairings; revoke a device's session to remove its existing access. Command-line
management is available through `./infinitus auth --help`.
=======
Manage pairing links and active client sessions in **Settings → Sharing & access** or via `t3 auth --help`.
>>>>>>> upstream-sync-986826178c-upstream-renamed

- **Scoped tokens**: Pass `--scope <scope>` (repeatable) to `t3 pair`, `t3 auth pairing create`, or `t3 auth session issue` to restrict permissions (e.g. `orchestration:read`, `source-control:write`, `filesystem:read`, `filesystem:write`, `terminal:operate`, `relay:configure`). Re-pair with a fresh link to change an existing client's scopes.
- **Deregister from Infinitus Connect**: Open your account menu → **Infinitus Connect → Deregister** (or `t3 connect unlink` / `t3 connect logout` on CLI hosts). Idle tunnels are automatically cleaned up after 5–10 minutes offline and recreated on reconnect (hosts on older versions offline for 7+ days need an update first).
- Treat pairing URLs and codes as passwords—never paste them into logs or screenshots.

## Desktop app as a remote only

Switch off **Settings → Environments → Local environment** in the desktop app to run with no local server, WSL backend, or incoming connections while continuing to drive remote hosts (if a local background service uses the same Infinitus home, **Open in** still works locally).

## Troubleshooting

<<<<<<< HEAD
The selected scopes replace the default permissions. The same option works with
`t3 auth pairing create` and `t3 auth session issue`; each command's
`--help` lists the available scopes. Without `--scope`, pairing tokens and issued
bearer sessions get the standard client permissions, including managing access.
Setting up or replacing an Infinitus Connect link requires the separate `relay:configure` permission.
A terminal or a full-access agent on the host can reach those as well, so a
client that should not manage access also needs to go without `terminal:operate`
and `orchestration:operate`.

To change an existing client's permissions, create a fresh pairing link with the
scopes it needs. In a browser opened directly on the environment, open that link
to replace the browser's current grant. For mobile or a saved remote environment
in web or desktop, use **Add Environment** with the fresh link or code; pairing
the same environment replaces its saved grant. Reconnecting alone does not change
permissions.

Grouping checkouts does not combine their permissions. Shared project settings
require `orchestration:operate` on every member environment; actions on one
checkout use that checkout's permissions.

`source-control:write` covers direct Git and pull request changes made from the
client: pushing, switching or creating branches, cloning, and removing
worktrees. It does not restrict what a task does. Starting a task in a new
worktree still creates that branch and worktree with `orchestration:operate`,
and the agent it runs can use Git however the environment allows.

Settings changes, provider management, environment maintenance, access
management, and Infinitus Connect preferences can each be granted separately. Setting
up or replacing an Infinitus Connect link requires the administrative
`relay:configure` permission. `relay:write` covers preferences and unlinking.
New pairings without `--scope` include the standard client permissions. Existing clients keep the
permissions they paired with and can stay connected after an update, but newly
separated features may require pairing again with the permissions they need.
Older clients may show controls that the server denies. Create a fresh pairing
link to change a client's permissions.

`filesystem:read` allows browsing host files, opening workspace files, and viewing
local changes. Add `filesystem:write` to allow editing files or saving plans to
the workspace. These scopes control direct file access from the client.

Some permissions also give a client indirect access. With `terminal:operate`,
a client can run commands that read or change any files the server’s OS account
can access, even when the pairing link omits file permissions. With
`relay:configure`, a client can replace the trusted issuer of pairing
credentials. Grant these permissions only to clients you trust with those
capabilities.

To remove an environment from Infinitus Connect, open your account menu's **Infinitus Connect**
page, or **Settings → Infinitus Connect** on mobile, and choose **Deregister**. This
revokes its cloud access and frees its host space even when the environment is
offline or has been wiped. When Infinitus Connect rejects a host's link, the host
shows that it was removed from Infinitus Connect. To link it again, turn on
**Infinitus Connect** in **Settings → Sharing & access** on web or desktop, or turn on
**Live Activity Updates** in **Settings → Notifications** on mobile; if it is
already on, turn it off and on again. Either needs a client paired with
`relay:read`, `relay:write`, and `relay:configure`. The desktop app's own session
and the startup pairing link include all three; a pairing link created in
**Settings → Sharing & access** needs `relay:configure` selected. You can also
run `infinitus connect link` on the host and then restart Infinitus there. A
command-line host that released its tunnel when it last stopped may link itself
again on its next start; run `infinitus connect unlink` on that host to keep it off.
Removing an environment from a device's connection settings only forgets it on
that device and doesn't change your Infinitus Connect account. A device keeps a saved
environment after it's deregistered until you remove it from that device.

When idle tunnel cleanup is enabled, Infinitus Connect removes a linked environment's
tunnel after it stays offline for several minutes. The environment stays linked
and keeps the same address. When the host starts again or wakes, Infinitus Connect
creates a replacement tunnel on its own. You do not need to pair again. Cleanup
usually runs five to ten minutes after the tunnel goes down.

Infinitus Connect also removes the tunnel of an environment running an older version of
Infinitus once it has been offline for seven days. That environment shows a message
asking you to update. Start Infinitus on that computer and update it to the latest
version; it reconnects at the same address without pairing again.

On a command-line host, `infinitus connect unlink` disables exposure while retaining
your login; `infinitus connect logout` also clears that login. Background-service
[removal](./background-service.md#manage-the-service) is separate.

Treat pairing URLs and authorization codes as passwords. Do not include them in
screenshots, logs, or bug reports.

## Infinitus Connect troubleshooting

When an Infinitus Connect connection fails, see
[Infinitus Connect troubleshooting](./t3-connect-troubleshooting.md). It explains each
error, where the problem is, and how to fix it.

## Using the Desktop App as a Remote Only

If a computer should only drive work running elsewhere, turn off its local environment. In the
desktop app, open **Settings → Environments** and switch off **Local
environment**. Infinitus restarts without a local server: no local agents or terminals run, WSL
backends stay off, and other devices can no longer connect to this computer. Your projects,
history, and saved connections are kept, and you keep working through pairing, Infinitus Connect, or SSH.
If a [background service](./background-service.md) on this computer uses the same Infinitus home, the
app still treats it as this computer: **Open in** and file reveal for its projects run here,
whichever connection you reach it through.

Switch **Local environment** back on in the same place to restart with your previous local
settings.
=======
See [Infinitus Connect troubleshooting](./t3-connect-troubleshooting.md) for step-by-step connection diagnostics, and [Outside agents](./outside-agents.md) for MCP connections.
>>>>>>> upstream-sync-986826178c-upstream-renamed
