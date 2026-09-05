# 01 — Stack: Swift 6.3.3 on Windows, one daemon target

## Decision

**Swift.** The daemon is a SwiftPM executable target `InfinitusWin`
(sources under `windows/`, added to `Package.swift` behind `#if os(Windows)`
so macOS/Linux builds are byte-identical to today). It links `InfinitusCore`
and reuses the feed reader, transcript logic, HTTP contract, pairing and
snapshot models verbatim.

Grounds (all verified on this box, 2026-09-04):

- Swift 6.3.3 is installed: `C:\Users\BM\AppData\Local\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin\swift.exe`
  (winget id `Swift.Toolchain`). Windows SDK 10.0.26100 present (no Visual
  Studio; the Windows Kits alone satisfy `swiftc`/`WinSDK`).
- A scratch copy of `Sources/InfinitusCore` (`C:\Users\BM\AppData\Local\Temp\inf-core-probe2`)
  **builds on Windows after two fences** (listed below). Nothing else in
  the ~40 core files errors.
- A `swiftc` probe against `WinSDK` confirmed the three Windows primitives
  the daemon needs: `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
  liveness, `GetProcessTimes` (creation FILETIME equals the session
  record's `procStart` / the key file's `procStartFt`), and
  `WaitNamedPipeW(path, 0)` → true on all 7 live `\\.\pipe\LOCAL\cc-msg-*`
  pipes (non-intrusive: no connect, no bytes).
- Rust / Node would re-implement `SessionFeedReader.parse` (597 lines) and
  drift from the Mac; rejected (README.md table). Node's `net.connect` on a
  named pipe would be the only thing simpler there.

Rust vs Swift, one line each, for the record: Rust has no code to share
and a second copy of every transcript rule; Swift shares ~2 000 lines of
already-tested core and costs two `#if os(Windows)` fences plus a
Winsock/named-pipe layer (~400 new lines).

## Toolchain setup on this box

Registered in the **user** PATH by the installer but NOT in every shell
(a Git Bash / PowerShell spawned before the install misses it). Every
build script must set:

```powershell
$env:Path = "C:\Users\BM\AppData\Local\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin;" +
            "C:\Users\BM\AppData\Local\Programs\Swift\Runtimes\6.3.3\usr\bin;" + $env:Path
$env:SDKROOT = "C:\Users\BM\AppData\Local\Programs\Swift\Platforms\6.3.3\Windows.platform\Developer\SDKs\Windows.sdk\"
swift --version   # Swift version 6.3.3
```

Install from scratch (a task for a fresh box; present here already):

```powershell
winget install --id Swift.Toolchain -e
```

Optional, for tunnel access (not installed; winget has it):

```powershell
winget install --id Cloudflare.cloudflared -e   # 2026.8.3 at time of writing
```

## Portability audit of `Sources/InfinitusCore`

| file | Windows status | note |
|---|---|---|
| `SessionFeed.swift` | ports verbatim | pure Foundation; one behaviour gap: `attachedImageIds` splits paths on `/` only, and `imageData` refuses `/`+`..` but not `\` — fix in-core behind no fence (both are string rules; `02-feed-readonly.md`) |
| `Transcript.swift` | ports verbatim | slug rule verified against the live `projects/` dir |
| `ClaudeSessions.swift` | **fence** | `isAlive` uses `kill(pid, 0)` (line 63). `#if os(Windows)`: `OpenProcess` + compare `GetProcessTimes` creation FILETIME to the record's `procStart` when present (pid reuse guard) |
| `PeerSocket.swift` | **fence** | lines 2–10: `#else import Glibc` → `#elseif canImport(Glibc)`; `write(_:to:timeout:)` body fenced `#if os(Windows) return false #else … #endif`. Everything else (`wrapBody`, `frames`, `peerToken`, `ownAddress`) is pure and reused for the pipe writer |
| `SessionInput.swift` | ports (one addition) | `defaultAttachmentsDir` needs a Windows branch: `%LOCALAPPDATA%\Infinitus\attachments`; `posixPermissions` attribute is ignored by corelibs-foundation on Windows (harmless) |
| `MirrorTransport.swift` | ports verbatim | whole HTTP contract; nothing platform-bound |
| `MirrorPairing.swift` | ports verbatim | token alphabet/length/mask/pairURL/parsePairURL/lanAddress/tailnetAddress |
| `MirrorClient.swift` | ports verbatim | device headers → "connected devices" listing |
| `MirrorRendezvous.swift` | ports verbatim | quick-tunnel republish (uses FoundationNetworking on non-Darwin; callers must `import FoundationNetworking` for URLSession) |
| `FleetMirror.swift`, `Models.swift`, `AccountEngine.swift` | port verbatim | snapshot/fleet/session models |
| `SessionProgress.swift` | ports verbatim | per-pid progress for the sessions rows |
| `SessionResume.swift` (`ResumeCoordinator`) | ports | `#if !os(iOS)` only; depends on `PtyHost`/`ProcessFacts` which compile |
| `PtyHosts.swift`, `PtyNudge.swift` | compile, do nothing | `PtyHosts.available()` looks for cmux/tmux/herdr binaries → `[]` on Windows; `ProcessFacts.tty/ancestors` shell out to `ps` → nil/[] (Foundation `Process` exists on Windows). Leave as-is; the daemon passes `hosts: []` |
| `PosixHTTPServer.swift` | already `#if canImport(Glibc)` | not compiled on Windows; its shape is the template for the Winsock listener |
| `Engines/*` (`CswapCLI`, `CLIProxyEngine`, `NineRouter`) | compile, unused | never invoked by the daemon |
| `AwsLogin.swift` | compiles, unused | route answers 404 on Windows |
| `LiveActivityPush.swift`, `PushTriggers.swift`, `UsageHistory.swift`, … | compile, unused | |
| `Tests/InfinitusCoreTests/SessionResumeTests.swift:7` | **fence** | `import Glibc` → `#elseif canImport(Glibc)`; its socket-bind tests must be `#if !os(Windows)` (AF_UNIX server in-test) |
| `Tests/InfinitusCoreTests/CLIProxyEngineTests.swift` | **fence** | needs `import FoundationNetworking` on non-Darwin (`URLRequest`, `URLProtocol`, `URLSessionConfiguration.ephemeral` — 15 errors on Windows, none on macOS). Fence the whole file `#if canImport(Darwin)` or add the import; verified 2026-09-04 by running `swift test` on the scratch copy |
| `Tests/InfinitusCoreTests/PosixHTTPServerTests.swift` | already fenced | `#if canImport(Glibc)` |

Not portable, not needed: `Sources/Infinitus/*` (AppKit/SwiftUI; includes
`ImageThumbnail.swift` — ImageIO), `Sources/InfinitusUI`, `Sources/InfinitusCLI`,
`Sources/InfinitusTray` (Linux/Waybar; `PairingStore.swift` is the model for
the Windows token store but lives in a Linux-only product).

## New Windows-only code (all under `windows/`)

| file | purpose | size |
|---|---|---|
| `windows/Sources/InfinitusWin/main.swift` | arg parsing (`serve`, `pair`, `sessions`, `send`), run loop | S |
| `windows/Sources/InfinitusWin/WinHTTPServer.swift` | Winsock HTTP/1.1 listener, thread-per-connection, same `Handler`/`Authorizer` shape as `PosixHTTPServer` | M |
| `windows/Sources/InfinitusWin/WinProcess.swift` | `isAlive(pid, procStart:)` via `OpenProcess`/`GetProcessTimes`; `machineName` via `GetComputerNameExW` | S |
| `windows/Sources/InfinitusWin/NamedPipeClient.swift` | `CreateFileW` + `WriteFile` of `PeerSocket.frames` bytes; `WaitNamedPipeW(0)` liveness | S |
| `windows/Sources/InfinitusWin/WinPairingStore.swift` | `%APPDATA%\Infinitus\pair-token`, user-only DACL | S |
| `windows/Sources/InfinitusWin/WinBonjour.swift` | `DnsServiceRegister` (windns.h, SDK 26100 has it) for `_infinitus._tcp` | M |
| `windows/Sources/InfinitusWin/WinAddresses.swift` | `GetAdaptersAddresses` IPv4 list for `pair` | S |
| `windows/Sources/InfinitusWin/Snapshot.swift` | builds `MirrorSnapshot` (synthetic fleet, liveSessions, progressByPid) | S |
| `windows/Sources/InfinitusWin/Routes.swift` | route handler mirroring `InfinitusTray.serve` (`Sources/InfinitusTray/InfinitusTray.swift:641-696`) + images | M |
| `windows/build.ps1`, `windows/run.ps1` | PATH/SDKROOT setup, `swift build --product infinitus-win`, firewall rule hint | S |
| `windows/README.md` | install/run/pair on Windows | S |

Package.swift change (only Windows sees it):

```swift
#if os(Windows)
targets.append(.executableTarget(
    name: "InfinitusWin",
    dependencies: ["InfinitusCore"],
    path: "windows/Sources/InfinitusWin",
    linkerSettings: [.linkedLibrary("ws2_32"), .linkedLibrary("dnsapi"), .linkedLibrary("iphlpapi")]))
products.append(.executable(name: "infinitus-win", targets: ["InfinitusWin"]))
targets.append(.testTarget(name: "InfinitusWinTests", dependencies: ["InfinitusWin"],
                           path: "windows/Tests/InfinitusWinTests"))
#endif
```

`InfinitusTray` must stop building on Windows or keep compiling: it
currently compiles (its Glibc code is fenced) — verified by the scratch
build only for the core; task W2 builds the whole package and fences
whatever the tray trips on.

## Build / run / test (this box)

```powershell
# one-time per shell
. .\windows\env.ps1        # sets Path + SDKROOT as above
swift build --product infinitus-win          # ONE --product per invocation (CLAUDE.md)
.\.build\debug\infinitus-win.exe sessions    # lists live sessions with liveness
.\.build\debug\infinitus-win.exe pair        # prints infinitus://pair?url=…&token=… (+QR if qrencode)
.\.build\debug\infinitus-win.exe serve       # 0.0.0.0:47824, Bonjour, token from store
swift test --filter InfinitusWinTests
swift test                                   # whole core suite, after the test fences
```

Firewall: inbound TCP 47824 must be allowed on the Private profile
(all three profiles are enabled on this box). `windows/run.ps1` prints the
exact `netsh advfirewall firewall add rule name="Infinitus" dir=in action=allow protocol=TCP localport=47824`
command; it never runs it unasked (needs elevation).

Dev instance rule (CLAUDE.md analogue): a second daemon MUST run with
`--port <other>`; the pairing token store is shared unless
`--token-file` is given.
