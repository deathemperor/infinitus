# 02 — Phase 1: sessions + transcript feed + images, read-only

Outcome: the phone lists the Windows box's live Claude Code sessions and
reads each one's chat feed with thumbnails, exactly as it does for the Mac.
No writes into any session.

## Discovery: `~/.claude` on Windows (verified 2026-09-04)

`ClaudeSessions.configHome()` already resolves `CLAUDE_CONFIG_DIR` else
`NSHomeDirectory() + "/.claude"`; on Windows `NSHomeDirectory()` is
`C:\Users\BM`, the mixed-slash path works with Foundation. Layout identical
to the Mac:

```
C:\Users\BM\.claude\sessions\<pid>.json               session record
C:\Users\BM\.claude\sessions\<pid>.<sha256hex>.key    peer token file
C:\Users\BM\.claude\projects\<slug>\<sessionId>.jsonl transcript
C:\Users\BM\.claude\projects\<slug>\<sessionId>\subagents\agent-<id>.{jsonl,meta.json}
C:\Users\BM\.claude\settings.json                     env (ANTHROPIC_BASE_URL …)
```

Record keys seen on the box: `cwd`, `entrypoint`, `kind`, `messagingSocketPath`,
`name`, `nameSince`, `nameSource`, `peerFeatures`, `peerProtocol` (1), `pid`,
`pidDomain` (`win32:…`), `procStart` (string, FILETIME ticks), `sessionId`,
`startedAt`, `status`, `statusUpdatedAt`, `updatedAt`, `version` (2.1.260).
`ClaudeSessions.list` reads only the keys it knows; unknown ones are ignored
— nothing to change but the liveness callback.

Key file keys: `peerToken` (32 chars), `procStartFt`, `pidDomain`.
`PeerSocket.peerToken(pid:claudeDir:)` finds it by `"\(pid)."` prefix +
`.key` suffix — works as-is.

### Slug derivation — verified

`Transcript.path` maps every character that is not a letter or number to
`-`. Windows cwd `D:\w\git\tools-org\infinitus` → `D--w-git-tools-org-infinitus`,
which is exactly the directory name under `projects\`. Checked for every
live record on the box: all 7 resolve directly; `Transcript.locate`'s scan
fallback (worktree case) also works since it lists `projects\` and looks for
`<sessionId>.jsonl`.

### Liveness on Windows

`ClaudeSessions.isAlive` → `kill(pid, 0)` does not exist. Windows branch:

```swift
#if os(Windows)
public static func isAlive(_ pid: Int32) -> Bool {
    guard pid > 1, let h = OpenProcess(UInt32(PROCESS_QUERY_LIMITED_INFORMATION), false, UInt32(pid)) else { return false }
    defer { CloseHandle(h) }
    var code: DWORD = 0
    return GetExitCodeProcess(h, &code) && code == UInt32(STILL_ACTIVE)   // 259
}
#endif
```

Plus pid-reuse guard in the daemon (not in core, keeps the core signature):
when the record has `procStart`, compare it to `GetProcessTimes` creation
FILETIME (`(hi << 32) | lo` as decimal string — confirmed equal on all 7
live sessions). Mismatch → treat as dead. A stale record whose pid was
reused by another program would otherwise show as a session.

Second liveness signal, pipe-level: `WaitNamedPipeW(messagingSocketPath, 0)`
returns true when a server instance is listening (probe: all 7 true,
`GetLastError()` 0). Used only for the sessions listing's `canMessage`
flag and the `sessions` CLI subcommand — never as the record filter (a
session in `--print` mode may have no pipe and still be alive).

## Snapshot (`GET /snapshot`)

The phone needs, minimally (`MirrorModel.refresh` + `SessionsScreen`):

```json
{
  "capturedAt": "2026-09-04T09:12:00Z",          // iso8601 (phone decodes .iso8601)
  "machineName": "BM-PC",                         // GetComputerNameExW(ComputerNameDnsHostname)
  "listJSON": "<base64 of AccountList JSON>",     // legacy field, must decode: see below
  "sessions": [ SessionPanelRow … ],              // SessionPanelRow.make(record:progress:)
  "fleets": [ {
      "engineID": "claude-code-windows", "provider": "claude",
      "accounts": [], "liveSessions": {
        "busy": 2, "total": 7, "idle": 4, "waiting": 1, "shell": 0, "unknown": 0,
        "sessions": [ {"pid": 1234, "cwd": "D:\\w\\…", "status": "busy", "kind": "interactive", "startedAt": 1757000000000.0} ]
      } } ],
  "progressByPid": { "1234": SessionProgress … }
}
```

- `listJSON`: encode `AccountList(schemaVersion: 1, activeAccountNumber: nil, accounts: [], liveSessions: <same>)`
  so a phone older than `fleets` still decodes (it wraps it as the cswap fleet).
  Check `AccountList`'s init/CodingKeys in `Sources/InfinitusCore/Models.swift`
  when implementing (W6) — it is `Codable`; all optional fields nil.
- `liveSessions.sessions`: cap and order as the Mac does (`Sources/Infinitus/MirrorExporter.swift:38-40`:
  busy/waiting first, busy before waiting, capped at 6 for `sessions` rows;
  `liveSessions.sessions` itself lists every live record — confirm against
  `CswapCLI`'s list mapping or leave uncapped; the phone sorts waiting-first).
- `startedAt`: epoch ms from the record's `startedAt` (already ms on Windows
  records — verify type when implementing; `procStart` is FILETIME, not this).
- `progressByPid`: `SessionProgress.read(sessionId:cwd:claudeDir:name:)` per
  record — pure transcript tail read, ports verbatim.
- `prefs`, `usageJSON`, `serviceStatus`, `engine`, `tokenRate`, `forecast`,
  `plan`, `awsLogins`: omitted (all optional). The phone's Fleet tab shows
  "no accounts" for this host — accepted for phase 1; `04-phone.md` hides
  the empty-accounts section for hosts whose fleet declares
  `accounts: []` and `engineID` starting with `claude-code-`.
- Recompute at most every 5 s on request (Mac: 30 s interval writer; the
  daemon has no other consumer, so compute lazily with a 5 s cache).
- Encoder: `JSONEncoder` with `.iso8601` dates (`MirrorExporter.swift:81`),
  response via `MirrorTransport.snapshotResponse`.

## Feed (`GET /sessions/<pid>/tail?n=&since=&wait=`)

Handler = `InfinitusTray.serve`'s tail branch verbatim
(`Sources/InfinitusTray/InfinitusTray.swift:653-670`):

1. `SessionFeedReader.waitForChange(pid:claudeDir:since:wait:)` — blocks the
   connection thread up to `min(wait, 25)` s, polling every 0.3 s
   (`stamp` = `"\(size)-\(mtimeMs)-\(status ?? "")"`; re-lists sessions each
   poll so a status flip counts). Thread-per-connection listener required
   (the Winsock server must not be single-threaded).
2. `ClaudeSessions.list(...).first { $0.pid == pid }` else 404.
3. `SessionFeedReader.read(record:claudeDir:limit:)` → `SessionFeed`
   (`pid, sessionId, cwd, status, waiting, items, name, stamp`), encoded
   with `.iso8601`.

Item parity with `SessionFeed.swift` — all pure, nothing to port:
kinds `user|assistant|tool|question|permission|result|limit|agent`;
consecutive tools collapse to `"<text> (×N · M errors)"`; `finalize`'s
waiting rule (`statusUpdatedAt` vs last item, open tool → `.permission`);
`attachAgents` from `<transcript-dir>/<sessionId>/subagents/` — Windows meta
keys confirmed: `agentType`, `description`, `toolUseId`, `spawnDepth`;
`presentableUserText` strips `<cross-session-message …>` + `phonePreface`
into `"<from-name>: body"`. Windows envelopes seen in real transcripts carry
`from="uds:\\\\.\\pipe\\LOCAL\\cc-msg-<hex>"`, `from-mode` = `bypass` |
`prompting`, sometimes `hop-chain=…` — the parser reads `from-name` only,
so all render.

Windows-specific text: `cwd` in the feed is a backslash path; the phone's
`shortCwd` uses `abbreviatingWithTildeInPath` (no-op on `D:\…`) — fine.

## Images (`GET /sessions/<pid>/images/<id>`)

Ids come from `SessionFeedReader.imageIds`: `t:<uuid>:<idx>` (base64 block in
the transcript entry) and `a:<file>` (a saved attachment named in the
`[attached: …]` line).

Two in-core string fixes (no fence; behaviour-neutral on Mac):

- `attachedImageIds` (`SessionFeed.swift:486`) takes the last `/`-component;
  a Windows attachment path is `C:\Users\BM\AppData\Local\Infinitus\attachments\<uuid>-<name>.png`.
  Split on both `/` and `\`.
- `imageData` (`SessionFeed.swift:514`) refuses `/` and `..`; add `\` and
  `:` (drive letters) to the refusal so `a:` ids can never escape
  `attachmentsDir`.

Thumbnailing: the Mac serves `ImageThumbnail.jpeg(maxPixels: 640)` via
ImageIO (`Sources/Infinitus/AppModel.swift` sessionImage provider). Windows
phase 1 serves the **original bytes** with the transcript's `media_type`
and a 5 MiB cap (a pasted terminal screenshot is ~200 KB base64; a phone
attachment ≤ 5 MiB by `SessionInput.maxAttachmentBytes`). `FeedThumbnail`
on the phone decodes any size. WIC downscale (`IWICImagingFactory`) is a
later, optional task (W16). Response: `MirrorTransport.imageResponse(data, contentType:)`
(carries `Cache-Control: private, max-age=86400`).

Attachments dir on Windows: `%LOCALAPPDATA%\Infinitus\attachments`
(`SessionInput.defaultAttachmentsDir` gets an `#if os(Windows)` branch;
`ProcessInfo.processInfo.environment["LOCALAPPDATA"]`, fallback
`NSHomeDirectory() + "\\AppData\\Local"`).

## Other routes in phase 1

- `POST /activities/token` → `204` (accept, discard: no push on Windows).
  Phone posts it on launch; a 404 would log an error each time.
- `POST /aws-login/*` → `MirrorTransport.notFoundResponse()`.
- `POST /sessions/<pid>/input` → phase 2; until then reply
  `{"outcome":"noChannel","detail":"input not enabled on this host yet"}`
  so the phone's `describe(outcome)` shows a sensible line.
- Unauthorized head rejected before body (`PosixHTTPServer.handle`'s
  authorize-first rule): the Winsock port keeps it.

## Bonjour on Windows

`DnsServiceRegister` (windns.h; SDK 26100 exports it; Dnscache service is
running on this box) advertises `<machineName>._infinitus._tcp.local` on
port 47824. The phone's `NWBrowser(for: .bonjour(type: "_infinitus._tcp"))`
resolves it like a Mac's. Fallback when registration fails (some Windows
builds refuse without the "mDNS" feature): `serve` prints the LAN address
and the `pair` URL; the phone's manual endpoint list covers it. Firewall
inbound rule needed either way.
