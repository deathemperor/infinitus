# 04 — Push and Devices panes

**Depends on `01`.** Compile against `01`'s final `SettingsPane`
protocol. Read `00-architecture.md` first.

Two panes, one task: both are about *reaching you when you're away*, both
handle secrets, and both are small enough that splitting them would cost
more in coordination than it saves.

---

# Pane A — Push

Mac source: `Sources/Infinitus/NotifyPane.swift` (170 lines) +
`Sources/InfinitusCore/PushTriggers.swift`.
Descriptor: `id: "push"`, glyph `` (Megaphone / Ringer), tint
`WinDark.rgb(220, 60, 60)` (the Mac's `.red`).

## The security rule, first

> Secrets (webhook URLs, bot tokens) travel over **stdin**, never argv;
> shown masked only. — CLAUDE.md

`CswapCLI.run(_:stdin:)` already exists and already does this
(`Engines/Cswap/CswapCLI.swift:53-60`: "the channel secrets travel on
(`cswap notify slack -`), so they never appear in an argv another process
could read out of `ps`"). Windows has `Get-Process`/`wmic` reading command
lines just as readily. Use `stdin`. There is no exception.

The secret is **never** stored by Infinitus. `cswap` owns `notify.json`
(owner-only). Infinitus reads back only the masked display strings from
`cswap notify --json` → `NotifyStatus{ slackWebhookUrl, telegramBotToken,
telegramChatId }` (`CswapCLI.swift:347-351`) — those fields are already
masked ("hooks.slack.com…9xQz"), never the secret.

## Channels

The task brief mentioned Discord, PushDeer and Bark. **They do not exist
in this codebase.** `cswap notify` supports `slack` and `telegram` only —
that is what `NotifyStatus` decodes and what `NotifyPane` offers. The
README's marketing line mentions Discord because a Slack-shaped webhook
also works against Discord's `/slack` endpoint, but there is no separate
channel.

So: **Slack and Telegram**, exactly as the Mac. If you find a `cswap`
build whose `notify --json` returns more fields, render them generically
and say so in the report — but do not invent CLI verbs.

Discord gets one line of help text under Slack: "A Discord webhook works
here too — append `/slack` to the Discord webhook URL."

## Layout

```
Away push — tells your phone which account is live
   After every switch, cswap pushes the new account's alias to each
   channel below. Secrets are stored by cswap in notify.json (owner-only)
   and shown masked. Infinitus never keeps a copy.

Also push when
   [x] All sessions finish working
       Fires once when every live Claude Code session has been idle for
       two refresh passes — turn gaps don't count.
   [x] All accounts are exhausted
   [x] The last alive account nears its limit
       Warns once when only one account still has quota and it crosses 90%.
   [x] A session waits on you
       Fires once per session when it stops at a permission prompt or a
       question.
   [x] A session needs an AWS login
       Fires once per session and profile when an aws command fails on an
       expired sign-in.

Slack
   Configured:  hooks.slack.com…9xQz          (or "no")
   Incoming webhook URL:  [•••••••••••••••••••••••••]
   [ Save webhook ]  [ Remove ]
   A Discord webhook works here too — append /slack to the Discord
   webhook URL.

Telegram
   Configured:  1234…AbCd   chat -100123456      (or "no")
   Bot token:   [•••••••••••••••••••••••••]
   Chat id:     [                          ]
   [ Save bot ]  [ Remove ]

[ Send test push ]
   <cswap's own reply, verbatim>
```

The five trigger labels and help strings are verbatim from
`NotifyPane.swift:107-125`. The 90% figure comes from
`PushTriggers.warnPct` — interpolate it, don't hardcode.

## Behaviour

- Trigger checkboxes write `settings.push*` immediately. **They are read
  by the daemon, not the tray** — see "Where the triggers actually run"
  below. Say so under the section: "These apply to the mirror daemon
  (`infinitus-win serve`); it re-reads them on start."
- `activate()` runs `cswap notify --json` through `ctx.async` and fills
  the two "Configured" lines. No engine → both read "cswap not found" and
  every control is disabled.
- Save webhook: trim; require `https://` prefix (the Mac's exact check,
  `NotifyPane.swift:35-39`, with the same message "Webhook URL must start
  with https://"); then `cswap notify slack -` with the URL on **stdin**;
  clear the field on success; reload the status.
- Save bot: require both token and chat id ("Telegram needs both a bot
  token and a chat id"); `cswap notify telegram - <chatid>` with the token
  on stdin. Note the chat id **is** argv — that matches the Mac and is
  correct: a chat id is not a secret.
- Remove: `cswap notify off slack|telegram`.
- Test: `cswap notify test`, show the trimmed output. Disabled when
  neither channel is configured and the webhook field is empty.
- The two secret EDITs are `ES_PASSWORD`. Clear them on success and on
  `deactivate()` — the raw secret must live in this process for as short a
  time as possible (the Mac's comment: "the raw webhook/token exists in
  this process exactly as long as the draft fields hold it").
- Zero the buffer after reading it into a `String`? Swift strings are not
  wipeable, so this is theatre — don't pretend. Just do not persist it and
  do not log it. **Never** put a secret in a status line, a balloon or
  `--probe` output.

## Where the triggers actually run

This is the part that needs thought, not just UI.

`PushTriggers` is a **stateful episode machine**: two consecutive quiet
ticks for "sessions finished", one-shot with re-arm for the others, a
seeding pass so a relaunch doesn't re-announce everything
(`PushTriggers.swift:10-23`). It needs a long-lived process ticking it
with fresh account + session data.

On Windows the long-lived process that has both is **`infinitus-win
serve`** — it already builds a snapshot every 5 s and knows the fleet. The
Linux tray does exactly this in `serve` and gates the flags from env vars
(`Sources/InfinitusTray/InfinitusTray.swift:568-613`).

So the plan:
1. Add the tick to `infinitus-win serve`, modelled line for line on
   `InfinitusTray.tickPushes` (`InfinitusTray.swift:583-612`) — same
   account-health mapping, same `liveSessions.sessions` pass-through, same
   `cswap notify push -` delivery with the message on stdin.
2. Read the flags from `WinSettingsStore.load()` at daemon start rather
   than from env (Windows has a settings file; the Linux tray does not).
   Keep `INFINITUS_PUSH_*` env overrides working for tests, same names.
3. Also raise a **tray balloon** for each message when the tray is
   running — a Windows user's "phone" is often the same machine. The
   daemon and tray are separate processes, so this needs a channel:
   the control pipe already exists
   (`windows/Sources/InfinitusWin/ControlServer.swift`,
   `NamedPipeClient.swift`). If wiring that is more than a few dozen
   lines, **skip the balloon** and note it — the push itself is the
   feature.

If the daemon-side tick turns out to be its own dispatch: land the pane
(config + toggles + test), have the toggles write `settings.json`, and
return `DONE_WITH_CONCERNS` with an issue for the tick. The toggles then
describe a thing that will start working, which is honest as long as the
pane says "applies to the mirror daemon". Do not silently ship dead
toggles.

---

# Pane B — Devices

Mac source: `Sources/Infinitus/SyncPane.swift` (536 lines) —
about a third of it ports.
Descriptor: `id: "devices"`, glyph `` (CellPhone), tint
`WinDark.rgb(60, 190, 220)` (the Mac's `.cyan`).

## Scope

| Mac section | Windows |
|---|---|
| Set-up walkthrough (4 live steps) | **port** — the checklist is the best part of this pane |
| Phone companion toggle + status | **port** — starts/stops `infinitus-win serve` |
| Pairing token: reveal/copy/regenerate | **port** |
| Pair a phone: QR + route list | **port** — QR rendered with GDI |
| Tailscale row | **port** (detect only) |
| Cloudflare quick tunnel | **drop** — macOS-only in this repo |
| Cloudflare named tunnel | **drop** — same |
| Rendezvous publish | **drop** — depends on the tunnel |
| Phone lock screen (APNs .p8) | **drop** — no APNs path on Windows |
| Connected devices list | **port if cheap** — needs the daemon to report clients |
| iCloud sync | **drop** |
| File export/import | **port** |

## Layout

```
Set up your phone                                     2 of 4
  [x] 1. Serve the fleet to my phone
         The toggle below. This box answers with its session snapshot;
         nothing leaves the machine otherwise.
  [x] 2. Put Infinitus on the phone
         The iOS companion lives in ios/ of the repo.
  [ ] 3. Pick how the phone reaches this PC
         Same Wi-Fi needs nothing. From anywhere: Tailscale on both
         devices.
  [ ] 4. Scan the QR from the phone
         On the phone: Settings → Mac connection → Scan QR.
  [ Copy for an AI agent ]   Token left out — Reveal it below to include it.

Phone companion
  [x] Serve the fleet to my phone
      listening on 47824 · 7 sessions served       (or "not running")
  Port:  [47824]                     (only editable while stopped)
  Pairing token:  2FDP••••••••••••••••PTVG
      [ Reveal ]  [ Copy ]  [ Regenerate ]
  Requests without `Authorization: Bearer <token>` (or `?t=<token>`) get
  a 401. The snapshot carries session names, folders and progress; never
  tokens or push secrets.
  ⚠ Inbound TCP 47824 must be allowed on the Private profile:
      netsh advfirewall firewall add rule name="Infinitus" dir=in
        action=allow protocol=TCP localport=47824
      [ Copy command ]

Pair a phone
  ┌──────────┐   Wi-Fi (LAN)
  │ ▄▄ ▄  ▄▄ │   http://192.168.6.12:47824              [ Copy ]
  │ █ ▄▄▄▄ █ │   Tailscale
  │ ▄▄  ▄ ▄▄ │   http://100.104.227.59:47824            [ Copy ]
  └──────────┘   [ Copy pair link ]
  One scan pairs every route. The phone tries them in this order and
  keeps whichever answers.

Anywhere
  Tailscale:  connected · 100.104.227.59        (or [ Get Tailscale… ])
  Free for personal use. Install it here and on the phone, sign both into
  the same tailnet, and a Tailscale route appears above by itself.
  Cloudflare tunnels are macOS-only in this build — use Tailscale, or
  your own reverse proxy to http://localhost:47824.

Settings file
  [ Export… ]  [ Import… ]
  Display prefs, custom themes and set cswap engine settings — the same
  file the Mac exports. Never credentials or push secrets.
```

## The QR — GDI, no dependency

The Mac uses CoreImage's `CIQRCodeGenerator`
(`MirrorPairingCenter.swift:39-56`). The Windows daemon shells `qrencode`
if it happens to be on PATH and otherwise prints "install qrencode for a
QR" (`windows/Sources/InfinitusWin/main.swift:209-216`). Neither is
available to a GUI pane that must always show a QR.

**Implement a minimal QR encoder in Core**, `QRCode.swift`:

```swift
/// A byte-mode QR encoder, just enough for a pair URL. Not a general
/// library: byte mode only, error-correction level M, the smallest
/// version that fits. Pure — no Foundation beyond Data, no platform
/// anything — so the Windows tray draws it with GDI, the Linux tray
/// could print it as blocks, and it is unit-testable.
public enum QRCode {
    public struct Matrix: Sendable, Equatable {
        public let size: Int              // modules per side
        public let modules: [Bool]        // row-major, size*size
        public subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }
    }
    /// nil when the text does not fit the supported versions.
    public static func encode(_ text: String, correction: Correction = .m) -> Matrix?
    public enum Correction: Sendable { case l, m, q, h }
}
```

Scope it honestly: a pair URL with two routes is ~140 characters
(`windows/README.md` shows a real one at 138). Byte mode, level M,
versions 1–10 covers up to ~213 bytes at level M — plenty. Do **not**
implement Kanji/alphanumeric modes or versions 11–40.

This is a known-hard-to-get-right piece of code. Requirements:
- Reed–Solomon over GF(256) with the standard QR generator polynomial.
- All 8 mask patterns evaluated with the four penalty rules; lowest wins.
- Format and (for version ≥ 7) version information bits.
- **Test against known vectors.** Encode `"HELLO WORLD"` and a real pair
  URL, and assert the module matrix against a reference produced by
  `qrencode` (or any trusted encoder) checked in as a fixture. A QR that
  encodes *something* but not the right thing is a silent failure — a
  phone just says "can't read this". Do not ship it without a
  round-trip-verified fixture.
- If the encoder proves to be more than this dispatch can hold: **fall
  back to `qrencode` on PATH when present, and otherwise show the pair
  URL as large selectable text with a Copy button plus "Install qrencode
  for a scannable QR, or type the address and token on the phone by
  hand."** That is a real, usable pairing path (the phone's Settings
  screen accepts a typed route + token). Report which route you took.

Rendering: `Matrix` → GDI. Quiet zone 4 modules, module size
`max(2, metrics.px(3))`, black modules on **white** (`FillRect` the whole
QR rect white first — a dark-background QR does not scan reliably on many
phone cameras; the Mac's pane explicitly puts `.background(.white)` behind
it). Paint in the pane's `WM_PAINT` region or into an owner-draw STATIC.

## Serving

The "Serve the fleet to my phone" toggle starts/stops the daemon. The
tray already has `startDaemon()` / `stopDaemon()` and, importantly,
`daemonAlreadyServing()` which reads the TCP table rather than connecting
(`main.swift:140-207` — connecting would need `WSAStartup`, which this
target never calls, so every probe would falsely answer "nothing is
serving" and a second daemon would steal the socket). **Reuse those; do
not write a second probe.**

State shown:
- daemon started by this tray → "listening on 47824".
- something else already on the port → "a mirror daemon is already
  serving port 47824" (the exact string `startDaemon` posts) and the
  toggle stays on but disabled with "started outside this tray".
- neither → "not running".

Port: editable only while stopped; writes `settings.mirrorPort`; passed
as `--port` when the tray starts the daemon. Warn if it is not 47824:
"The phone's QR carries this port; a paired phone needs a fresh scan
after a change."

## Pairing token

`WinPairing.token()` reads `%APPDATA%\Infinitus\pair-token` and
deliberately **never creates one** — minting here would leave the daemon
serving a different secret than the URL just copied
(`WinPairing.swift:22-25`). Respect that:
- no token → "No pairing token yet." + `[ Create one ]` which shells
  `infinitus-win pair` (the CLI owns creation) and re-reads.
- Reveal/Hide toggles between `MirrorPairing.mask(token)` and the raw
  token. Default masked — "settings panes get shared in screenshots, and
  this one is a read key" (`SyncPane.swift:26-28`).
- Copy → `WinPairing.setClipboardText` (exists).
- Regenerate → `infinitus-win pair --rotate`, then a warning that every
  paired phone must scan again. Confirm first (`MessageBoxW`).

Routes come from `WinPairing.pairingURL(port:)`, which already builds
LAN + tailnet endpoints via `MirrorPairing.lanAddress` /
`.tailnetAddress` over `WinAddresses.ipv4()`. Show them as a list with
per-route Copy, and the full `infinitus://pair?…` behind "Copy pair
link". Re-probe addresses on a 3 s pane timer so a Tailscale connect
appears without reopening (the Mac does exactly this,
`SyncPane.swift:34`).

Tailscale detection: `MirrorPairing.tailnetAddress(in: WinAddresses.ipv4())`
non-nil → connected + the address. Otherwise offer the download link
(`TailscaleStatus.downloadURL` is macOS-app code; use
`https://tailscale.com/download/windows` and open it with
`ShellExecuteW`). Do **not** try to detect an installed-but-disconnected
Tailscale by hunting the registry — connected/not-connected is the only
distinction that matters for a route.

## The agent brief

`SyncPane.agentBrief` (`SyncPane.swift:409-463`) generates a pasteable
markdown brief with the live state and the exact commands. It is one of
the nicest things in the Mac pane and it is pure string building. Port it
with Windows commands:

- serving toggle → this pane;
- phone app → the same `ios/` instructions;
- routes → Wi-Fi/Tailscale, no tunnels;
- verify → `curl.exe` (ships with Windows 10+) or
  `Invoke-WebRequest`:
  ```
  curl.exe -s -o NUL -w "%{http_code}\n" -H "Authorization: Bearer <token>" http://<host>:47824/snapshot
  ```
- firewall → the `netsh` line.

The token rides along **only while Reveal is on**, and the brief says so
otherwise — same rule as the Mac.

## Export / import

`SyncSnapshot` (`Sources/InfinitusCore/SettingsSync.swift`) is portable
Core: `{ app: [String: JSONValue], themes: [RowTheme], engine: [String: String] }`.

- Export: `GetSaveFileNameW`, default name `infinitus-settings.json`.
  Build `app` from `WinSettings` (encode to JSON, decode as
  `[String: JSONValue]` — one round trip, no hand-mapping), `themes` from
  `RowTheme.loadCustom(from: windowsThemesURL)`, `engine` from the *set*
  entries of `cswap config list --json` (`entry.isSet` only — the Mac's
  scope, "the spec table holds no secrets").
- Import: `GetOpenFileNameW`, decode, apply: `app` → `WinSettingsStore`
  (unknown keys ignored), `themes` → `RowTheme.saveCustom`, `engine` →
  one `cswap config set` per key (the CLI re-validates, so this can only
  ever be too lenient — `SettingsSync.swift:16-18`).
- Say plainly, on screen: "Never credentials or push secrets."
- A Mac-exported file must import cleanly and vice versa. Test this with
  a fixture from the Mac's own export.

## Tests

Core:
- `QRCodeTests` — the fixture round trip described above, plus:
  `testMatrixIsSquareAndOdd`, `testQuietZoneIsCallerOwned` (the matrix
  excludes it), `testTooLongReturnsNil`.
- `SyncSnapshot` round trip with a `WinSettings`-shaped `app` dict.

`InfinitusWinUI`:
- `testWalkthroughStepsFromState` — a pure
  `PairingChecklist.steps(serving:port:lastServed:routes:) -> [Step]`
  with `done` flags; assert each combination. (Extract it exactly as the
  Mac has `SyncPane.steps`.)
- `testAgentBriefOmitsTokenWhenMasked` / `testIncludesWhenRevealed`.
- `testPairURLListsLANThenTailnet` — order matters; the phone tries them
  in order.
- `testPortChangeWarnsWhenNotDefault`.

## Acceptance

**Push**
1. Pane shows masked status for both channels, or "cswap not found".
2. Saving a Slack webhook works, the field clears, the status shows a
   masked value, and `Get-Process`/Process Explorer never shows the
   secret in a command line — verify by watching while saving.
3. A non-https webhook is refused with the message, no shell call.
4. Remove clears the channel.
5. Test push delivers and shows cswap's reply.
6. Trigger toggles persist and (per the note) either drive the daemon or
   are documented as pending.

**Devices**
7. The checklist reflects real state and ticks as steps complete.
8. Toggle starts the daemon; a daemon started elsewhere is detected and
   not duplicated.
9. QR renders and **a real phone scans it** — this is the acceptance, not
   "a QR appeared". If the fallback path was taken, the typed route +
   token pairs a real phone instead.
10. Reveal/Copy/Regenerate behave; regenerate warns first.
11. Tailscale route appears within ~3 s of connecting, without reopening.
12. Firewall command copies.
13. Export then import on the same machine is a no-op; a Mac export
    imports without error.
14. Agent brief pastes into a terminal and the `curl.exe` line returns
    200 with the right token, 401 with a wrong one.

## Report

Status; files; tests; commit. Plus:
- QR route taken (own encoder / qrencode / typed fallback) and the
  fixture used to verify it;
- whether the push trigger tick landed in `infinitus-win serve` or was
  deferred (+ issue);
- whether tray balloons for pushes landed;
- confirmation, in words, that no secret reaches argv, a log, a status
  line or `--probe`.
