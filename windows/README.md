# Infinitus on Windows (`infinitus-win`)

Windows daemon and CLI for the [Infinitus](https://github.com/deathemperor/infinitus)
phone companion (`ios/InfinitusMobile`), driving Claude Code instances running
natively on Windows (Windows Terminal + `claude.exe`).

## Why

Claude Code's built-in `--remote-control` is disabled whenever a custom
`ANTHROPIC_BASE_URL` is set (e.g. local swap proxies, corporate gateways, or 9Router).
Infinitus bypasses this limitation by reading Claude Code's local state outside
the engine:
- Session descriptors and credentials: `%USERPROFILE%\.claude\sessions\*.json` and `*.key`
- Transcripts and tool progress: `%USERPROFILE%\.claude\projects\<slug>\*.jsonl`
- Input delivery: Claude Code's local named pipes (`\\.\pipe\LOCAL\cc-msg-<hex>`)

## Prerequisites

- **Windows 10 / 11** (x86_64)
- **Swift Toolchain 6.3+**:
  ```powershell
  winget install --id Swift.Toolchain -e
  ```
- **Windows SDK** (e.g. Windows SDK 10.0.26100, installed via Visual Studio Installer or Windows SDK standalone installer)
- **Optional**: `qrencode` on `PATH` for rendering terminal QR codes during pairing

## Build & Environment

Before building or running `swift`, configure toolchain paths and SDK root in your PowerShell session:

```powershell
. .\windows\env.ps1
```

Build the executable:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\build.ps1
```

Or invoke `swift build` directly:

```powershell
swift build --product infinitus-win
```

Run test suite:

```powershell
swift test --filter InfinitusWinTests
```

Binary location: `.\.build\debug\infinitus-win.exe`.

---

## Install & Release Flow

Debug binaries in `.\.build\debug` require Swift toolchain runtime DLLs on `PATH`
(or sourcing `windows\env.ps1`). A bare double-click or autostart without the
environment fails with exit `3221225781` (`0xC0000135`, `STATUS_DLL_NOT_FOUND`)
— and it fails **silently**, with no window, no message and an empty stderr, so
it reads as "the app did nothing" rather than as an error.
Furthermore, pointing autostart at `.build\` breaks whenever `.build\` is cleaned.

To run a debug binary without `env.ps1` — a double-click, a smoke script, any
launcher that doesn't inherit your shell — stage the DLLs beside it once:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\stage-dlls.ps1 -TargetDir .build\debug
```

Re-run it after any toolchain upgrade. It is idempotent and safe while the tray
or daemon is running: identical files are skipped, and anything genuinely locked
is reported rather than throwing.

A **debug** build needs one DLL a release build does not — `swiftSwiftOnoneSupport.dll`,
the unoptimized-stdlib shim that `-Onone` imports. `stage-dlls.ps1` adds it
automatically when the target directory is named `debug` (or with `-DebugBuild`);
without it you get the same silent `0xC0000135` even though the other 17 are present.

`windows\install.ps1` builds both `infinitus-win` and `infinitus-tray-win` in release
configuration, copies them to `%LOCALAPPDATA%\Infinitus\bin\`, and stages the 17
required Swift runtime DLLs alongside them (via the same script) so they run
standalone anywhere without sourcing `env.ps1`.

### Install to `%LOCALAPPDATA%\Infinitus\bin`

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

### Install with Autostart (Start with Windows)

Sets `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (`Infinitus Tray`) to point at the installed release binary:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Autostart
```

> **Debug vs Release Autostart Warning**: Toggling "Start with Windows" from the
> debug tray UI sets the Run registry key to `.\.build\debug\infinitus-tray-win.exe`.
> Always use `windows\install.ps1 -Autostart` so Windows starts the standalone release
> binary at `%LOCALAPPDATA%\Infinitus\bin\infinitus-tray-win.exe` upon user login.

### Uninstall

Stops any running installed daemon or tray instances, removes the autostart Run key, and deletes `%LOCALAPPDATA%\Infinitus\bin`:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1 -Uninstall
```

---

## Subcommands & Real Output

All examples below show verified output from `infinitus-win 0.4.2` on Windows 11.

### Version: `--version` / `-V`

Prints the current version matching the Infinitus release track.

```powershell
.\.build\debug\infinitus-win.exe --version
```
```text
infinitus-win 0.4.2
```

### Sessions: `sessions`

Inspects all Claude Code sessions on this host. Verifies process liveness via
`OpenProcess` and matches process creation `FILETIME` against session records to
prevent stale PID reuse. Probes the named pipe (`\\.\pipe\LOCAL\cc-msg-*`) with
`WaitNamedPipeW` without connecting or sending bytes.

```powershell
.\.build\debug\infinitus-win.exe sessions
```
```json
[
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\tools-org\\infinitus",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-4c6d4d1d5fa3ebe5312b917ef19769b8",
    "name" : "infinitus-ec",
    "pid" : 1840,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\ref-app\\app-game-mod",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-c44459752049fd89d08286a068e8e26a",
    "name" : "app-game-mod-0b",
    "pid" : 3116,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\ref-app\\app-game-mod",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-67d05089c995560e3a84d076ab583125",
    "name" : "app-game-mod-5c",
    "pid" : 9484,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\beam-org\\beam-mediaplayer",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-d7f25f89b86ad3e6a1c71991eaca622b",
    "name" : "beam-mediaplayer-1b",
    "pid" : 15308,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\proxmox",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-ff3358d06e81627cb4c605ea625674f9",
    "name" : "proxmox-7f",
    "pid" : 17532,
    "pipe" : true,
    "status" : "idle"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\tools-org\\infinitus",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-f26987bb665b0570ab76adde3e9d8338",
    "name" : "infinitus-c9",
    "pid" : 24928,
    "pipe" : true,
    "status" : "busy"
  },
  {
    "alive" : true,
    "cwd" : "D:\\w\\git\\proxmox",
    "kind" : "interactive",
    "messagingSocketPath" : "\\\\.\\pipe\\LOCAL\\cc-msg-605c45444ced46a9475d727760e9db37",
    "name" : "proxmox-56",
    "pid" : 34272,
    "pipe" : true,
    "status" : "idle"
  }
]
```

### Pairing: `pair`

Generates and stores a 24-character base32 pairing token, detects non-loopback
IPv4 adapters (LAN, Tailscale), and formats the `infinitus://pair` URL. If `qrencode`
is installed, outputs an ANSI QR code for phone scanning.

```powershell
.\.build\debug\infinitus-win.exe pair
```
```text
infinitus://pair?url=http%3A%2F%2F192.168.6.12%3A47824&url=http%3A%2F%2F100.104.227.59%3A47824&token=2FDPAIJT3S5BSLM4EM6RPTVG
pairing token 2FDP••••••••••••••••PTVG — `infinitus-win pair --show` prints it
install qrencode for a QR
```

To print unmasked token without URL formatting:
```powershell
.\.build\debug\infinitus-win.exe pair --show
```
```text
2FDPAIJT3S5BSLM4EM6RPTVG
```

Supported flags:
- `--show`: Print stored unmasked token
- `--rotate`: Generate and store new pairing token
- `--stdin`: Read token from standard input
- `--token-file <path>`: Read token from file
- `--port <number>`: Override port in generated URLs (default `47824`)

### Snapshot: `snapshot`

Generates the exact JSON payload expected by the phone remote at `GET /snapshot`.
Contains a synthetic fleet descriptor (`claude-code-windows`), session counters,
and parsed per-PID progress (goal, nowDoing, active model, token metrics).

```powershell
.\.build\debug\infinitus-win.exe snapshot
```
```json
{
  "capturedAt" : "2026-09-04T10:34:57Z",
  "fleets" : [
    {
      "accounts" : [

      ],
      "engineID" : "claude-code-windows",
      "liveSessions" : {
        "busy" : 1,
        "idle" : 6,
        "sessions" : [
          {
            "cwd" : "D:\\w\\git\\tools-org\\infinitus",
            "kind" : "interactive",
            "pid" : 1840,
            "startedAt" : 1788508650335,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\ref-app\\app-game-mod",
            "kind" : "interactive",
            "pid" : 3116,
            "startedAt" : 1788504390771,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\ref-app\\app-game-mod",
            "kind" : "interactive",
            "pid" : 9484,
            "startedAt" : 1788495982861,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\w\\git\\beam-org\\beam-mediaplayer",
            "kind" : "interactive",
            "pid" : 15308,
            "startedAt" : 1788495783800,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\w\\git\\proxmox",
            "kind" : "interactive",
            "pid" : 17532,
            "startedAt" : 1788494441754,
            "status" : "idle"
          },
          {
            "cwd" : "D:\\w\\git\\tools-org\\infinitus",
            "kind" : "interactive",
            "pid" : 24928,
            "startedAt" : 1788508350623,
            "status" : "busy"
          },
          {
            "cwd" : "D:\\w\\git\\proxmox",
            "kind" : "interactive",
            "pid" : 34272,
            "startedAt" : 1788495375043,
            "status" : "idle"
          }
        ],
        "shell" : 0,
        "total" : 7,
        "unknown" : 0,
        "waiting" : 0
      },
      "provider" : "claude"
    }
  ],
  "listJSON" : "eyJzY2hlbWFWZXJzaW9uIjoxLCJhY2NvdW50cyI6W10sImxpdmVTZXNzaW9ucyI6eyJ3YWl0aW5nIjowLCJidXN5IjoxLCJ1bmtub3duIjowLCJ0b3RhbCI6NywiaWRsZSI6Niwic2hlbGwiOjAsInNlc3Npb25zIjpbeyJzdGF0dXMiOiJpZGxlIiwia2luZCI6ImludGVyYWN0aXZlIiwic3RhcnRlZEF0IjoxNzg4NTA4NjUwMzM1LCJjd2QiOiJEOlxcd1xcZ2l0XFx0b29scy1vcmdcXGluZmluaXR1cyIsInBpZCI6MTg0MH0seyJjd2QiOiJEOlxccmVmLWFwcFxcYXBwLWdhbWUtbW9kIiwic3RhcnRlZEF0IjoxNzg4NTA0MzkwNzcxLCJwaWQiOjMxMTYsInN0YXR1cyI6ImlkbGUiLCJraW5kIjoiaW50ZXJhY3RpdmUifSx7ImN3ZCI6IkQ6XFxyZWYtYXBwXFxhcHAtZ2FtZS1tb2QiLCJzdGFydGVkQXQiOjE3ODg0OTU5ODI4NjEsImtpbmQiOiJpbnRlcmFjdGl2ZSIsInN0YXR1cyI6ImlkbGUiLCJwaWQiOjk0ODR9LHsiY3dkIjoiRDpcXHdcXGdpdFxcYmVhbS1vcmdcXGJlYW0tbWVkaWFwbGF5ZXIiLCJzdGFydGVkQXQiOjE3ODg0OTU3ODM4MDAsImtpbmQiOiJpbnRlcmFjdGl2ZSIsInN0YXR1cyI6ImlkbGUiLCJwaWQiOjE1MzA4fSx7ImN3ZCI6IkQ6XFx3XFxnaXRcXHByb3htb3giLCJzdGFydGVkQXQiOjE3ODg0OTQ0NDE3NTQsInBpZCI6MTc1MzIsInN0YXR1cyI6ImlkbGUiLCJraW5kIjoiaW50ZXJhY3RpdmUifSx7ImN3ZCI6IkQ6XFx3XFxnaXRcXHRvb2xzLW9yZ1xcaW5maW5pdHVzIiwic3RhcnRlZEF0IjoxNzg4NTA4MzUwNjIzLCJraW5kIjoiaW50ZXJhY3RpdmUiLCJzdGF0dXMiOiJidXN5IiwicGlkIjoyNDkyOH0seyJjd2QiOiJEOlxcd1xcZ2l0XFxwcm94bW94Iiwic3RhcnRlZEF0IjoxNzg4NDk1Mzc1MDQzLCJraW5kIjoiaW50ZXJhY3RpdmUiLCJzdGF0dXMiOiJpZGxlIiwicGlkIjozNDI3Mn1dfX0=",
  "machineName" : "DESKTOP-M4T7IB",
  "progressByPid" : {
    "15308" : {
      "gitBranch" : "main",
      "goal" : "check and add to our ts as new source  \"D:\\w\\git\\ref-spotiflac\\SpotiFLAC-Extension\\extensions\\",
      "lastActivityAt" : "2026-09-04T08:07:24Z",
      "model" : "glm-5.3-flash",
      "name" : "beam-mediaplayer-1b",
      "nowDoing" : "Done — pushed (`4be9fbf`). Full setup:",
      "outputTokens" : 3798,
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "17532" : {
      "gitBranch" : "HEAD",
      "goal" : "how to create a new proxmox user and grant key access for our AI agent to work with it as root",
      "lastActivityAt" : "2026-09-04T08:43:14Z",
      "model" : "glm-5.3-flash",
      "name" : "proxmox-7f",
      "nowDoing" : "Physical answer — **the card was never installed in hpz2**:",
      "outputTokens" : 60310,
      "phase" : "building",
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "1840" : {
      "gitBranch" : "windows-remote",
      "goal" : "Another Claude session sent a message:",
      "lastActivityAt" : "2026-09-04T10:21:44Z",
      "model" : "glm-5.3-flash",
      "name" : "infinitus-ec",
      "nowDoing" : "Both sends now delivered (held one released, named one direct). Done.",
      "outputTokens" : 990,
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "24928" : {
      "gitBranch" : "windows-remote",
      "goal" : "check if we can run and remote control windows with our windows terminal & CC",
      "lastActivityAt" : "2026-09-04T10:33:47Z",
      "model" : "claude-opus-5",
      "name" : "infinitus-c9",
      "nowDoing" : "Status: three Sonnet coders spawned as asked, two alive.",
      "outputTokens" : 57226,
      "phase" : "exploring",
      "recentOutputTokens" : 18211,
      "retrying" : false
    },
    "3116" : {
      "gitBranch" : "HEAD",
      "goal" : "can we find where is claude code installe",
      "lastActivityAt" : "2026-09-04T07:35:33Z",
      "model" : "glm-5.3-flash",
      "name" : "app-game-mod-0b",
      "nowDoing" : "Analysis complete — and it flips my earlier answer. **You already have both.** N",
      "outputTokens" : 45065,
      "phase" : "exploring",
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "34272" : {
      "gitBranch" : "HEAD",
      "goal" : "how to create a new proxmox user and grant key access for our AI agent to work with it as root",
      "lastActivityAt" : "2026-09-04T08:43:14Z",
      "model" : "glm-5.3-flash",
      "name" : "proxmox-56",
      "nowDoing" : "Physical answer — **the card was never installed in hpz2**:",
      "outputTokens" : 60310,
      "phase" : "building",
      "recentOutputTokens" : 0,
      "retrying" : false
    },
    "9484" : {
      "gitBranch" : "HEAD",
      "goal" : "check  \"D:\\ref-app\\xiaomiwallet\"  we need to find hidden api to change xiaomi nfc to emylate nfc c",
      "lastActivityAt" : "2026-09-04T04:26:18Z",
      "model" : "glm-5.3-flash",
      "name" : "app-game-mod-5c",
      "nowDoing" : "Status:",
      "outputTokens" : 63607,
      "phase" : "exploring",
      "recentOutputTokens" : 0,
      "retrying" : false
    }
  },
  "sessions" : [
    {
      "goal" : "check if we can run and remote control windows with our windows terminal & CC",
      "nowDoing" : "Status: three Sonnet coders spawned as asked, two alive.",
      "phase" : "exploring",
      "repo" : "infinitus",
      "retrying" : false,
      "status" : "busy"
    }
  ]
}
```

Supported flags:
- `--claude-dir <path>`: Override Claude configuration root (defaults to `%USERPROFILE%\.claude`)

### Input Injection: `message`

Injects a cross-session message directly into a running Claude Code session over its
named pipe (`\\.\pipe\LOCAL\cc-msg-*`).

Use `--dry-run` to view the exact wire frames (auth line + user frame) without sending:

```powershell
.\.build\debug\infinitus-win.exe message --pid 1840 --dry-run "hello from cli"
```
```text
{"token":"e80c951659f38d5e0cdfa3165c009032","type":"auth"}
{"from":"uds:\\\\.\\pipe\\LOCAL\\infinitus-29616","message":{"content":"<cross-session-message from=\"uds:\\\\.\\pipe\\LOCAL\\infinitus-29616\" from-name=\"Infinitus app\" from-mode=\"bypass\">\nhello from cli\n<\/cross-session-message>","role":"user"},"msg_id":"49a52a9c-5483-4881-be21-b74033f8b149","msgV":1,"priority":"next","type":"user"}
```

Live delivery:

```powershell
.\.build\debug\infinitus-win.exe message --pid 1840 "hello from cli"
```
```text
delivered to 1840 (infinitus-ec)
```

Supported flags:
- `--pid <number>`: Target session process ID (required)
- `--dry-run`: Format and print NDJSON wire frames without connecting
- `--claude-dir <path>`: Override Claude configuration root

### Resume: `resume`

Nudges every limit-stopped session, or one with `--pid`. `--dry-run` lists what
it would nudge; `--explain` shows what the AUTOMATIC pass would decide right
now and why — the only way to read the gate's reasoning without waiting for a
tick. Neither writes anything.

```powershell
.\.build\debug\infinitus-win.exe resume --explain
```
```text
engine: C:\Users\BM\.local\bin\cswap.exe
active account: none
would nudge nothing: no active account
```

Supported flags:
- `--pid <number>`: Only this session
- `--dry-run`: List stopped sessions and their pipe reachability
- `--explain`: Print the automatic pass's decision, with the gate's reason
- `--claude-dir <path>`: Override Claude configuration root

### Account switch: `control switch`

Asks the engine to switch; no number rotates. The engine decides — a refusal is
reported in its own words.

```powershell
.\.build\debug\infinitus-win.exe control switch 3
```
```text
{
  "error" : "No accounts are managed yet"
}
```

---

## Pairing Security & Storage

The pairing token is stored at:
```text
%APPDATA%\Infinitus\pair-token
```

Security configuration:
- The token file is protected with a user-only Discretionary Access Control List (DACL)
- Only `SYSTEM`, `Administrators`, and the current user SID have full control access
- Inheritance is disabled (`PROTECTED_DACL_SECURITY_INFORMATION`)

---

## Firewall Note

To allow incoming connections from the Infinitus phone client on your local Wi-Fi,
allow inbound traffic on TCP port `47824` on the Private network profile:

```powershell
netsh advfirewall firewall add rule name="Infinitus" dir=in action=allow protocol=TCP localport=47824
```

---

## `serve` — the phone's HTTP surface

`infinitus-win serve [--port N] [--claude-dir P] [--token-file P] [--auto-resume]`
runs the server the phone talks to. Without `--token-file` it uses the stored
pairing token, so `pair` then `serve` is the whole setup. `--auto-resume` adds
the nudge pass described under [Automatic resume](#automatic-resume).

```
> infinitus-win serve
listening on 47824
  http://192.168.6.12:47824
  http://100.104.227.59:47824
token 2FDP••••••••••••••••PTVG — `infinitus-win pair` prints the pairing URL
if the phone can't reach it, allow inbound TCP 47824:
  netsh advfirewall firewall add rule name="Infinitus 47824" dir=in action=allow protocol=TCP localport=47824
```

Routes (all require `Authorization: Bearer <token>`, or `?t=<token>`):

| route | answers |
|---|---|
| `GET /snapshot` | the fleet + session snapshot, 5 s cache |
| `GET /sessions/<pid>/tail?n=&since=&wait=` | the session's feed; holds up to 25 s when `since` matches the current stamp |
| `GET /sessions/<pid>/images/<id>` | a feed image, original bytes, 5 MiB cap |
| `POST /sessions/<pid>/input` | `message`, `resume` or `key`; delivery over the named pipe |
| `POST /activities/token` | accepted and discarded (no APNs on Windows) |

Verified on this box (2026-09-04): 401 without a token, 200 with; snapshot
listing 7 live sessions; a tail carrying real items with `canMessage=true`,
`keys=false`, `permissionMode=bypassPermissions`; long-poll returning in 8 ms
on a stale stamp and holding 4.1 s on a current one; a `message` answering
`{"channel":"socket","outcome":"delivered"}` and appearing in the target
session's transcript; a `key` answering `{"outcome":"noSurface"}`.

**Held for approval.** When the sending and receiving sessions' permission
modes differ in class, Claude Code holds the message for its user to approve
rather than delivering it straight to the model. The daemon reports the write
that succeeded; the phone shows `permissionMode` so it can say so.

---

## Custom API Acceptance (W12)

Recorded 2026-09-04 against `docs/plan-windows/05-custom-api.md`:

This host runs Claude Code configured with a local swap proxy (`ANTHROPIC_BASE_URL=http://127.0.0.1:20128/v1` in `~/.claude/settings.json`). The acceptance checks verify that the Infinitus remote path remains independent of the API endpoint:

1. **Step 1 (Proxy active — baseline)**: **PASS**
   - 7 live Claude Code sessions listed via `infinitus-win sessions` and `/snapshot` (`liveSessions.total: 7`, `alive: true`, `pipe: true`).
   - Feed tail `/sessions/1840/tail` retrieved live turns, showing model `glm-5.3-flash` (proxy-aliased) alongside `canMessage: true`, `keys: false`, and `permissionMode: default`.
   - Cross-session message injection via named pipe verified live: sending `infinitus-test-ping` to PID 1840 delivered `<cross-session-message from="uds:\\.\pipe\LOCAL\infinitus-..." from-name="Infinitus app" ...>` directly into the session inbox, and the session replied `"Pong. infinitus-ec alive."`.

2. **Step 2 (Unset `ANTHROPIC_BASE_URL`)**: **NOT RUN (credential constraint)**
   - The auth token on this host (`ANTHROPIC_AUTH_TOKEN: sk-9a...`) is issued by and scoped to the local proxy. Direct connection to `api.anthropic.com` fails authentication or requires interactive browser login (`claude login`), which cannot be run in headless automation.
   - Code verification confirms independence: `infinitus-win` reads session descriptors, transcripts, and pipes directly from the filesystem (`%USERPROFILE%\.claude\sessions` and `projects`), never touching `ANTHROPIC_BASE_URL` in `settings.json`.

3. **Step 3 (Unreachable upstream failure mode)**: **NOT RUN (production safety constraint)**
   - The local proxy on port 20128 is a shared background service (PID 24776) powering all 7 active sessions, including the active orchestrator session (PID 24928). Pointing it to an unreachable upstream would disrupt live work across the host.
   - Code verification in `Transcript.swift:119-125` confirms: `isLimitStop` only matches `entry["type"] == "assistant"` with `entry["error"] == "rate_limit"`. Upstream network/proxy errors surface as `system`/`api_error` entries, yielding `isLimitStop == false`; `findStopped` skips them and no resume nudge is attempted.

---

## Automatic resume

`serve --auto-resume` runs the nudge pass on a 60 s tick: a Claude Code
session stopped at a usage limit is messaged back to work over its named
pipe, the same `ResumeCoordinator` the Mac runs (CLAUDE.md: this mechanism
lives in Infinitus, never engine-side).

**Off unless asked for** — a nudge types into someone's session — and it
needs the swap engine, which is the quota signal it reasons about. Without
cswap it says so once and stays idle; `infinitus-win resume` still nudges
by hand.

Every guard the Mac learned the hard way is kept, because they are the
difference between resuming work and the 2026-09-01 runaway that fired
three nudges in one minute into a session that was still limited:

- **`ResumeGate`** — something must have changed SINCE the stop: a switch,
  or a usage poll that postdates it. An "account is alive" verdict that
  predates the stop is exactly the stale read that caused the loop.
- **Standing stops are never retried** — only a new one is, so a message
  held for review can't be queued twice.
- **A 600 s per-session cooldown** — each burned retry mints a fresh stop
  id, which is how the runaway escaped the "already nudged" set.

No pty fallback: `hosts: []`, so a session whose pipe is gone is reported
unreachable rather than typed at (Windows Terminal has no send-keys).

To see what it would decide right now, without writing anything:

```powershell
.\.build\debug\infinitus-win.exe resume --explain
```

It prints the active account, whether that account can take work, and one
line per limit stop — nudge or hold, with the gate's reason. `ResumeSupervisorTests`
pins the decisions, driving account state through `INFINITUS_ACCOUNTS_JSON`
so no real credential is involved.

## Switching accounts

Clicking an account in the tray asks the engine to switch to it; "Switch to
next account" rotates. `infinitus-win control switch [N]` does the same over
the control pipe.

Account policy stays the **engine's** (CLAUDE.md): these forward the ask and
report the engine's answer, including a refusal verbatim. The active account
and any account the engine holds out of rotation are shown greyed — a click
would only earn a refusal.

cswap reports failures as JSON on **stdout** with an empty stderr
(`{"error":{"message":"No accounts are managed yet"}}`, exit 1 — verified
2026-09-04), so the reason is read from stdout; reading stderr alone showed a
bare exit code. A refusal carried in the body on exit 0 is treated as a
failure too, rather than reported as a switch that never happened.

## Backup & restore

```powershell
.\.build\debug\infinitus-win.exe export accounts.json            # every account
.\.build\debug\infinitus-win.exe export one.json --account 2     # just slot 2
.\.build\debug\infinitus-win.exe export all.json --full          # + ~/.claude.json
.\.build\debug\infinitus-win.exe import accounts.json            # additive restore
.\.build\debug\infinitus-win.exe import accounts.json --force --yes
```

**The backup file is a credential file.** It carries each account's
`credentials.claudeAiOauth` block in plain text — cswap's own header says
`"encrypted": false` (verified 2026-09-04). Anyone who reads it can use those
accounts. Keep it out of git and off shared drives, and delete it once you have
restored what you needed. `export` says this every time unless you pass
`--quiet`.

Guards, because both verbs are one typo from something you can't undo:

- **`export` never overwrites.** An existing file at that path is refused — it
  may be your only copy of a credential.
- **`import` is additive by default**, and cswap also repairs slots whose
  refresh token has died. That is the common restore and it does not touch live
  accounts, so try it before reaching for `--force`.
- **`import --force` replaces existing accounts and requires `--yes`.** There is
  no dry-run and no undo; what is in the file wins. Unconfirmed, it exits 2 and
  prints how to proceed. It also reports how many slots stand to be replaced —
  from `cswap list`, since CLAUDE.md forbids reading `~/.claude-swap-backup`.

Verified round trip (2026-09-04): a throwaway API-key slot exported to an
808-byte file, the slot removed, then restored from the backup with its number
and email intact — plus `--force --yes` over a live slot, and both `--account`
and `--full`. `BackupTests` pins the guards; `CswapBackupTests` pins the
`--force` detection.

On the Mac the same thing is in **Settings → Accounts**: "Back up accounts…" and
"Restore…", with the plaintext-credential warning always on screen. A restore
tries the safe import first and only asks about replacing accounts if the engine
says it would have to.

## Accounts panel

`Open accounts panel…` in the tray menu (or `infinitus-tray-win --panel`) is
the Windows answer to the Mac popup's account grid: one row per account with
its 5h / 7d / per-model gauges, reset countdowns, the active account banded,
spent windows in red, and a click to switch.

It is **owner-drawn GDI**, because there is no alternative. SwiftUI, AppKit and
UIKit ship only inside Apple's SDKs — the Windows Swift SDK has 25 modules
and none of them is a UI framework (verified 2026-09-04) — so the Mac's
18,478 lines of SwiftUI (`Sources/Infinitus` + `Sources/InfinitusUI`) cannot
compile here at all, which is why `Package.swift` fences them behind
`#if os(macOS)`. Every rectangle in this panel is placed by hand.

The numbers and strings come from **InfinitusCore**, never a second
implementation: `GaugeMath` for remaining/pace, `WeeklyRoll.displayPct` for the
weekly roll-over, `ResetLabel` for countdowns, `AccountVitals` for death. That
is what stops the panel and the Mac popup disagreeing about the same account.

What it deliberately does not copy: the burn overlays, HP-drop zooms and intro
choreography. Those are CAAnimations on the Mac, and CLAUDE.md's hard-won fact
is that five SwiftUI-driven effects at 20 fps idled the pop-out at 43% CPU
(0.4% as layer animations). GDI has no equivalent compositor, so imitating them
would need a repaint timer — the exact thing that rule forbids. Pace is still
shown, statically: a warm marker where the burn should be when usage runs ahead
of the clock, cool when it runs behind. Measured idle with the panel open:
**0.13% CPU, 30 MB**.

`INFINITUS_ACCOUNTS_JSON=<path>` renders a fixture instead of the engine — the
only way to exercise the gauge painting locally, since a token account reports
`usage: null` and draws no bars.

## Not Yet Implemented

1. **WIC Thumbnails**:
   Image downscaling to ≤ 640px JPEG using Windows Imaging Component (`IWICImagingFactory`). The image route serves original bytes today.
2. **Engines other than cswap**:
   The Mac registers CLIProxy, NineRouter and Codex as well; Windows reads cswap only.
3. **Cloudflare tunnel**:
   `NamedTunnel` is macOS-only, so remote access is LAN/tailnet (or your own tunnel) rather than a managed hostname.
