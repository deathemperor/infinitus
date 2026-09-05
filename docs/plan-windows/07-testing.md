# 07 — Testing and acceptance on this box

All commands assume `windows/env.ps1` was dotted (PATH + SDKROOT,
`01-stack.md`). Box: Windows 11 IoT Enterprise LTSC 2024, Swift 6.3.3,
pwsh 7.6.5, Node 24.20.0 (used only for ad-hoc HTTP/pipe probes), claude
2.1.260, Windows Terminal present.

## Unit tests (XCTest, `swift test`)

Core suite on Windows (`Tests/InfinitusCoreTests`, after the fences in
W1): the scratch run showed the only compile blockers are
`SessionResumeTests.swift` (Glibc) and `CLIProxyEngineTests.swift`
(FoundationNetworking). Gate: `swift test` exits 0 on Windows with those
two fenced; `SessionFeedTests`, `MirrorTransportTests`, `MirrorPairingTests`,
`SessionInputTests` (the pure ones), `ResumeGateTests`, `SessionProgressTests`
run unchanged and prove the shared code.

New `windows/Tests/InfinitusWinTests`:

| test | proves |
|---|---|
| `SlugTests.testLiveProjectsResolve` | for every record in a fixture `sessions/` dir (copied from this box with pids/ids anonymised), `Transcript.path` exists under a fixture `projects/` dir — Windows drive-letter + backslash slugs |
| `WinProcessTests.testSelfIsAlive` / `testDeadPidIsNotAlive` | `OpenProcess` liveness on `GetCurrentProcessId()` and on a just-exited `cmd /c exit` child |
| `WinProcessTests.testProcStartMatchesFileTime` | `GetProcessTimes` creation FILETIME string equals what a record would carry (self-spawned child, read via `wmic`-free path: compare to `Process.launch` time within 2 s) |
| `NamedPipeTests.testWriteRoundTrip` | test creates its own `\\.\pipe\LOCAL\infinitus-test-<uuid>` server (`CreateNamedPipeW`, byte mode), client writes `PeerSocket.frames(...)`, server reads back byte-equal NDJSON (two lines, sorted keys, envelope newlines exact) |
| `NamedPipeTests.testMissingPipeIsFalse` | `WaitNamedPipeW` false + write false for a nonexistent pipe |
| `WinHTTPServerTests.*` | port of `PosixHTTPServerTests` (no token 401, wrong token 401, right token 200, POST body whole, unauthorized head rejected before body, unknown route 404) over Winsock loopback |
| `SnapshotTests.testDecodesOnPhoneShape` | the daemon's snapshot JSON decodes with `JSONDecoder` + `.iso8601` into `MirrorSnapshot`, `fleets[0].liveSessions.sessions` non-empty, `listJSON` decodes as `AccountList` |
| `ImageIdTests.testBackslashAttachmentPath` | `attachedImageIds("… [attached: C:\\…\\attachments\\x.png]") == ["a:x.png"]`; `imageData` refuses `a:..\\x.png` and `a:C:x.png` — lives in core tests (`SessionFeedTests`) since the fix is in core |
| `PairingStoreTests` | token file created once, normalised on read, reused |

## Integration on the live box (manual, scripted where possible)

`windows/smoke.ps1` runs these in order, printing PASS/FAIL, against a
dev instance on `--port 47825` (never 47824 while a real daemon runs):

1. **Build**: `swift build --product infinitus-win` exit 0.
2. **Sessions**: `infinitus-win sessions` lists ≥1 row; every row's `alive`
   true and `pipe` true for interactive sessions (7 expected today).
3. **Serve + auth**: start `serve --port 47825 --token-file <tmp>`;
   `Invoke-WebRequest http://127.0.0.1:47825/snapshot` → 401 with
   `WWW-Authenticate: Bearer realm="infinitus"`; with `-Headers @{Authorization="Bearer <t>"}` → 200 JSON, `machineName` non-empty, `fleets[0].liveSessions.total` ≥ 1.
4. **Feed**: `GET /sessions/<pid>/tail?n=10` → 200, `items` non-empty for a
   session with a transcript; `stamp` present.
5. **Long-poll**: `GET …/tail?n=10&since=<stamp>&wait=5` returns after ~5 s
   with the same stamp when idle; type one line into that session's
   terminal and the same call returns in < 1 s with a new stamp.
6. **Images**: pick a feed item with `images`, `GET /sessions/<pid>/images/<id>`
   → 200, `Content-Type: image/*`, bytes decode (PowerShell
   `[System.Drawing.Image]::FromStream`).
7. **Input** (phase 2): `POST /sessions/<pid>/input` body
   `{"kind":"message","text":"ping from smoke"}` → `{"outcome":"delivered","channel":"socket"}`;
   within 5 s the transcript tail contains `<cross-session-message from="uds:` … `from-name="Infinitus app"`
   and the feed's newest user item text is `Infinitus app: ping from smoke`
   (proves the envelope re-rendered byte-equal — an "unidentified session"
   rendering fails this step). Use a scratch session started for the
   smoke (`wt -w 0 nt claude`), not a working one.
8. **Resume**: `{"kind":"resume","text":""}` → delivered; transcript
   contains `[Infinitus] Continue where you left off`.
9. **Key**: `{"kind":"key","text":"enter"}` → `{"outcome":"noSurface"}`.
10. **Bonjour**: `dns-sd -B _infinitus._tcp` (Bonjour SDK) or the phone on
    the same Wi-Fi lists the host; if `DnsServiceRegister` failed, `serve`
    printed the fallback address and the manual endpoint works.
11. **Perf** (CLAUDE.md spirit): daemon idle CPU over 15 s with one phone
    long-poll open < 1 % (`Get-Counter '\Process(infinitus-win)\% Processor Time'` sampled twice);
    private bytes stable ± 2 MB over 5 min of long-polling.

## Phone acceptance (simulator on the Mac, or device)

- Pair the phone with the Mac (existing) and with the Windows daemon
  (`pair` QR shown in Windows Terminal via `qrencode -t ANSIUTF8` if
  installed, else the URL typed): both hosts appear in Settings → Hosts;
  neither token overwrote the other.
- Sessions tab shows two sections with host emoji/labels; opening a
  Windows session streams its feed; sending a message shows up in the
  Windows Terminal session and echoes back into the feed as
  `Infinitus app: …`.
- Kill the Windows daemon: its section shows the per-host offline status;
  the Mac section keeps working.
- Simulator dev seam: `INFINITUS_MIRROR_PATH` still points at one file —
  extend to `INFINITUS_MIRROR_PATHS` (`;`-separated) for a two-host
  fixture capture (W13).

## CI

`tools/e2e.sh` is macOS-only and stays so. Add `windows/ci.ps1` (build +
`swift test --filter InfinitusWinTests` + core tests) for a self-hosted
Windows runner later; not wired into GitHub Actions in this plan (no
Windows runner with Swift is configured; CLAUDE.md: push nothing unasked).
