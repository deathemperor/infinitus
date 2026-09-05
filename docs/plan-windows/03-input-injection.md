# 03 — Phase 2: input injection over Claude Code's named pipe

Outcome: `POST /sessions/<pid>/input` with `kind: message` (text +
attachments) or `kind: resume` lands in the Windows session's inbox, byte-
compatible with what Claude Code's own `SendMessage` writes. `kind: key`
answers `noSurface` (no PTY on Windows — see the end).

## The peer protocol (peerProtocol 1) — from `PeerSocket.swift`, unchanged

Transport differs (AF_UNIX socket on Mac → named pipe on Windows); the
bytes do not. `PeerSocket.frames(text:token:from:messageId:)` produces:

```
{"token":"<peerToken>","type":"auth"}\n
{"from":"<ADDR>","message":{"content":"<ENVELOPE>","role":"user"},"msgV":1,"msg_id":"<uuid, lowercase>","priority":"next","type":"user"}\n
```

(`JSONSerialization` with `.sortedKeys`; NDJSON; one write of both frames.)

Envelope (`PeerSocket.wrapBody`), newlines exact — the receiver re-renders
the parse and demands byte equality:

```
<cross-session-message from="<ADDR>" from-name="Infinitus app" from-mode="bypass">
<body>
</cross-session-message>
```

Body escape: `</(?=cross-session-message)` → `<\\` (regex in `wrapBody`).

Sender address `ADDR` (`PeerSocket.ownAddress`): `"uds:" + percent-escaped path`
with the safe set `A-Za-z0-9%:_/.\-`. On the Mac it is `/tmp/infinitus-<pid>.sock`
(no real socket; one-way). Windows senders observed in real transcripts use
`from="uds:\\\\.\\pipe\\LOCAL\\cc-msg-<hex>"` (backslashes doubled by JSON;
the raw string is `uds:\\.\pipe\LOCAL\cc-msg-<hex>`). Backslash is in the
safe set, so a Windows daemon address `uds:\\.\pipe\LOCAL\infinitus-<pid>`
is emitted unescaped. The receiver only needs the address to parse; no pipe
is ever bound (verify with W9's acceptance: the feed must show
`Infinitus app: <body>`, not "an unidentified session").

Token: `peerToken` from `C:\Users\BM\.claude\sessions\<pid>.<sha256hex>.key`
(`PeerSocket.peerToken(pid:claudeDir:)` — prefix match, works on Windows).

Message text framing (`SessionInput.deliver`, `.message` case): the phone's
text is prefixed with `PeerSocket.phonePreface` unless it already starts
with `[Infinitus]`; attachments are written to `attachmentsDir` as
`<UUID>-<sanitizedName>` and appended as `\n\n[attached: <path>, <path>]`.
`.resume` sends `SessionInput.continueText()` (carries `HH:mm:ss` so a
second tap is not deduplicated by CC).

## Windows transport: named pipe client

`messagingSocketPath` in a Windows record is `\\.\pipe\LOCAL\cc-msg-<32hex>`
(7 seen; all appear in `\\.\pipe\` listing). Write path:

```swift
// windows/Sources/InfinitusWin/NamedPipeClient.swift
static func write(_ payload: Data, to pipePath: String, timeoutMs: DWORD = 5000) -> Bool {
    // 1. WaitNamedPipeW(path, timeoutMs) — false → no server instance (dead session)
    // 2. CreateFileW(path, GENERIC_WRITE | GENERIC_READ, 0, nil, OPEN_EXISTING, 0, nil)
    //    INVALID_HANDLE_VALUE → false (ERROR_PIPE_BUSY: retry once after WaitNamedPipeW)
    // 3. WriteFile whole payload (loop until written == count); FlushFileBuffers
    // 4. CloseHandle
}
```

Wiring: `SessionInput.deliver(..., hosts: [], socketSend: { record, text in
NamedPipeClient.send(pipePath: record.messagingSocketPath, text: text, pid: record.pid, claudeDir: …) })`
where `send` = `PeerSocket.frames(...)` + `write`. `deliver` already
returns `Reply(outcome: "delivered", channel: "socket")` on success; with
`hosts: []` a failed write falls through to `noSurface` (record has a pipe
path) or `noChannel` (empty path). Both already have phone-side wording
(`SessionFeedScreen.describe`).

Message mode byte-order: read side is CC's own; CC on Windows reads NDJSON
from the pipe in byte mode (CC's own Windows sender uses `net.connect` on
the pipe path — same byte stream). Do NOT open with `PIPE_READMODE_MESSAGE`.

Timeout: the Mac uses 5 s send/recv timeouts. `WriteFile` on a pipe with a
listening server returns promptly; guard with `WaitNamedPipeW(5000)` up
front and treat `ERROR_PIPE_BUSY`/`ERROR_FILE_NOT_FOUND` as not delivered.

## Queue / approval semantics (observed in real Windows transcripts)

- `priority: "next"` queues the message for the next turn. A mid-turn
  session receives it and processes it after the current turn — CC shows
  it in the transcript as a user entry (`SessionFeedTests.testMidTurnQueuedPromptShowsAsUserMessage`
  models this). The daemon does not need a "running" outcome for messages
  (`running` is PTY-only).
- **Held messages.** Transcripts on this box contain
  `held for approval (recipient: uds:\\\\.\\pipe\\LOCAL\\cc-msg-<hex>…` lines,
  and `permission-mode` entries with `permissionMode` = `bypassPermissions`
  or `default`. A message with `from-mode="bypass"` into a session in
  `default` mode may be HELD until the user approves it in that terminal.
  `wrapBody` fixes `from-mode="bypass"` on purpose (it is the value that
  reaches sessions in either mode; a held message is still delivered to the
  inbox). Consequence: **the daemon reports `delivered`/`socket` even when
  the receiver holds it** — same as the Mac. No phone-side approval surface
  is possible (approval is a keypress in the receiving terminal, and there
  is no key channel on Windows). Document it in the phone's outcome text
  (W14: append " — if the session runs in default permission mode, approve
  it in its terminal") only when the session's most recent `permission-mode`
  transcript entry is `default`; that entry type is in the transcript tail
  the feed reader already parses (add a `permissionMode: String?` field to
  `SessionFeed`, additive optional, W9).
- Duplicate suppression: CC drops a message identical to the previous one
  from the same sender (`ResumeCoordinator` comment). `continueText()`
  embeds the time for this reason; phone messages are user-typed.

## Sessions listing with liveness

`GET /snapshot`'s `liveSessions.sessions` already implies "process alive"
(records filtered by `isAlive`). Add pipe liveness as an additive optional
on `SessionDetail`? No — `SessionDetail` is a cross-engine model decoded by
the Mac too. Instead expose it in `SessionFeed` (per-session, already
additive-friendly): `canMessage: Bool?` = `!messagingSocketPath.isEmpty &&
peerProtocol == 1 && WaitNamedPipeW(path, 0)`. The phone disables the
composer when `canMessage == false` (W14). CLI: `infinitus-win sessions`
prints `pid  status  alive  pipe  cwd` for local debugging.

## `kind: key` on Windows

`PtyHosts.available()` returns `[]` (no cmux/tmux/herdr). Windows Terminal
has no send-keys / read-screen CLI; ConPTY injection would need to be the
terminal's parent. `deliver(.key)` therefore returns `noSurface`, which the
phone already renders ("this session has nowhere to receive input right
now"). Hide the key row on the phone for hosts whose feed says
`keys: false` (additive optional in `SessionFeed`, W9/W14). Permission
prompts and AskUserQuestion answers on Windows go as a message ("2" or
"yes") — CC treats a queued user message during a permission prompt as
input only after the prompt resolves, so the phone's permission card must
say "answer in the terminal" on key-less hosts. Deferred: a ConPTY-hosting
launcher (`infinitus-win launch claude …`) that owns the pty and can type
into it — out of scope for this plan.

## Security notes

The pairing token is the only lock on a route that can write into any
session's inbox on the machine. Same posture as the Mac (MirrorServer
comment: "the token is the only lock"). Keep: 401 before body read; 24 MiB
cap only on the input route; attachments written with a fresh UUID name
into a user-only directory; message length cap 4000 and control-character
filter (`SessionInput.isValidMessage`). The peer token file is 0600 on
Unix; on Windows it inherits the user profile's ACL — the daemon runs as
the same user, reads it, never copies it anywhere.
