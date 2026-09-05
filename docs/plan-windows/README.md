# Infinitus on Windows — plan set

Goal: the Infinitus phone remote (ios/InfinitusMobile) drives Claude Code
running natively on Windows (Windows Terminal + `claude.exe` 2.1.260), with
the custom-API path (`ANTHROPIC_BASE_URL` → local swap proxy) intact. Claude
Code's own `--remote-control` is hard-disabled under a custom base URL, so
the remote has to come from outside CC — exactly what Infinitus already does
on the Mac by reading `~/.claude` and talking CC's peer socket.

Written 2026-09-04 from the repo at `3fa96ea` and from the live box
(`C:\Users\BM\.claude`, 7 live sessions, Swift 6.3.3 installed). Every
protocol detail below was read from code or probed on the box; nothing is
guessed. Files:

| file | covers |
|---|---|
| `README.md` | this: architecture decision, diagram, multi-host/token model |
| `01-stack.md` | Swift-on-Windows stack, portable-vs-not file list, build/run |
| `02-feed-readonly.md` | phase 1: sessions + transcript feed + images, read-only |
| `03-input-injection.md` | phase 2: CC peer protocol over named pipes |
| `04-phone.md` | iOS changes: multi-host fleet merge, per-host token, target UX |
| `05-custom-api.md` | proxy-independence, verified |
| `06-nudge-resume.md` | resume/nudge parity — what ports, what is deferred |
| `07-testing.md` | tests + acceptance runnable on this box |
| `TASKS.md` | numbered, dependency-ordered task list |

## Decision: a Windows mirror daemon speaking the phone's HTTP surface

Build `infinitus-win` — a headless Windows daemon (Swift, see `01-stack.md`)
that serves the **same HTTP routes the Mac app serves**
(`Sources/InfinitusCore/MirrorTransport.swift`), so the existing phone client
(`ios/InfinitusMobile/NetworkFleetMirror.swift`) talks to it unchanged at the
wire level:

```
GET  /snapshot                          → MirrorSnapshot JSON (iso8601 dates)
GET  /sessions/<pid>/tail?n=&since=&wait=   → SessionFeed JSON, long-poll ≤25 s
GET  /sessions/<pid>/images/<id>        → image bytes, Cache-Control: private, max-age=86400
POST /sessions/<pid>/input              → SessionInput.Request → SessionInput.Reply (24 MiB cap)
POST /activities/token                  → 204 (accepted, ignored on Windows)
POST /aws-login/start|code|callback     → 404 on Windows (capability absent)
auth: Authorization: Bearer <24×base32> or ?t=; 401 "pairing token required\n"
     + WWW-Authenticate: Bearer realm="infinitus"; every reply Connection: close
```

The daemon reads only Claude Code's own files (`~/.claude/sessions/*.json`
+ `.key`, `~/.claude/projects/<slug>/<sessionId>.jsonl`) and writes only to
CC's peer pipe `\\.\pipe\LOCAL\cc-msg-<32hex>` — the Windows twin of the
Mac's `PeerSocket.write` over the AF_UNIX `messagingSocketPath`. No engine
(`cswap`) involvement at all: on Windows there is no cswap, so the snapshot
carries one synthetic fleet with zero accounts and `liveSessions` populated
(`04-phone.md` covers the phone's empty-accounts handling).

Why this and not the alternatives:

| option | verdict | reason |
|---|---|---|
| **Windows daemon, same HTTP surface** (chosen) | do | phone wire contract already exists and is tested (`Tests/InfinitusCoreTests/MirrorTransportTests.swift`); InfinitusCore's feed/transcript/pairing code compiles on Windows with two fences (probed, `01-stack.md`); the Mac app stays untouched |
| SSH `PtyHost` from the Mac app into Windows | reject | needs a Mac up 24/7 as a relay; `PtyHosts` is a PTY read/write surface (tmux/screen/iTerm) — Windows Terminal has no send-keys/read-screen CLI, so there is nothing for a PtyHost to drive; transcript reads over SSH would re-implement the feed reader remotely with 0.3 s polling over the wire |
| full Windows port of the Infinitus app (tray UI, engines) | reject | AppKit/SwiftUI targets are `#if os(macOS)`-fenced in `Package.swift`; cswap is macOS-only; the phone only needs sessions + feed + input; a tray UI is a later, separate project |
| Rust / Node daemon | reject | would re-implement `SessionFeed.parse` (≈600 lines of transcript semantics: tool collapse, agent attach, image ids, envelope stripping) and drift from the Mac; Swift is installed on the box and the core compiles |

## Diagram

```
                 ┌────────────────────────────┐
                 │  iPhone · InfinitusMobile  │
                 │  hosts: [Mac, Win-BM, …]   │  per host: label, emoji,
                 │  sessions merged, keyed    │  endpoints[], token
                 │  by (host, pid)            │
                 └──────┬─────────────┬───────┘
      Bonjour _infinitus._tcp        │        Cloudflare tunnel / tailnet /
      (same Wi-Fi, port 47824)       │        typed host:port
                 ┌──────┴──────┐  ┌──┴──────────────────────────┐
                 │  Mac app    │  │  infinitus-win (daemon)      │
                 │  Infinitus  │  │  Windows 11, Swift 6.3.3     │
                 │  (as today) │  │  same routes, same JSON      │
                 └──────┬──────┘  └──┬───────────────┬───────────┘
                    cswap --json     │ reads         │ writes
                    ~/.claude        │ %USERPROFILE%\.claude\   \\.\pipe\LOCAL\cc-msg-<hex>
                    peer AF_UNIX     │ sessions/*.json,*.key    (CC peer protocol v1,
                                     │ projects/<slug>/*.jsonl   NDJSON auth + user frame)
                                     └───────────────┴───────────┐
                                                 claude.exe ×N in Windows Terminal
                                                 ANTHROPIC_BASE_URL → local proxy (untouched)
```

## Multi-host reality and the token model

Today's phone is single-host: `NetworkFleetMirror.tokenKey = "mirror_pair_token"`
is ONE string, `mirror_manual_endpoints` is a failover list for ONE Mac,
`MirrorModel.applyPairing` REPLACES the list, and long-poll/POST go to
`candidateEndpoints().first` only. Scanning the Windows daemon's QR would
therefore unpair the Mac.

Decision: **per-host tokens, per-host records on the phone.**

- Each daemon (Mac app, Windows daemon) mints and shows its own 24×base32
  token (`MirrorPairing.generateToken`, stored via the Windows analogue of
  `Sources/InfinitusTray/PairingStore.swift`). No shared secret crosses
  machines; revoking one host is deleting its record.
- Phone stores `[MirrorHost{id, label, emoji, endpoints:[String], token}]`
  (`04-phone.md`); the legacy single token + list migrate into host #0
  ("Mac") on first launch.
- The pair URL gains `&name=<machine>` (already `machineName` in the
  snapshot, so the QR is optional: the phone labels a host from its first
  `/snapshot`). `MirrorPairing.parsePairURL` (`Sources/InfinitusCore/MirrorPairing.swift:100-114`)
  reads only `token|t` and `url|endpoint` query items and ignores others,
  so an extra `name=` is already tolerated by old phones.
- Sessions from every host merge into one list; each `SessionDetail` row is
  keyed `(hostID, pid)` and tagged with the host's emoji/label. Feed, images
  and input route to the session's own host — never to "first endpoint".
- Shared-token alternative (one token typed into both hosts) rejected: still
  needs the phone to know which host owns which pid, so per-host records are
  required anyway; a shared secret only adds a leak surface.

## Non-negotiables carried over from CLAUDE.md

- Engine fully isolated: the daemon never reads `~/.claude-swap-backup/*`;
  it reads only Claude Code's own files. (Windows has no cswap; the point
  stands for any future Windows engine.)
- Resume-nudge lives in Infinitus: `SessionResume` is ported, not rebuilt.
- Secrets over stdin, never argv: `--token-file` / `INFINITUS_PAIR_TOKEN`
  stdin, shown masked.
- Bundle/socket ids untouched; the daemon has none. Dev instances of the
  daemon MUST use a distinct `--port` (there is no `INFINITUS_CONTROL_SOCKET`
  on Windows, but the same collision rule applies: never bind 47824 twice).
- Push nothing to any remote; commit locally.
- Every release updates `site/` and the README with the Windows feature.
