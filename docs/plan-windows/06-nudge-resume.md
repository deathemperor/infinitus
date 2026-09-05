# 06 — Nudge / resume parity on Windows

CLAUDE.md: the resume-nudge mechanism lives in Infinitus. On Windows it is
**ported, socket-channel only**; the terminal (PTY) channel and the
engine-driven trigger are deferred with reasons.

## What ports as-is (`Sources/InfinitusCore`)

- `Transcript.findStopped(sessions:claudeDir:)` — limit-stop detection
  (`assistant` entry with `isApiErrorMessage == true`, `error == "rate_limit"`,
  no `retryAttempt`), `stopUuid`, `stoppedAt`, `limitText`. Pure.
- `Transcript.verdict` — `waiting | burned(newStopUuid) | done`. Pure.
- `ResumeGate.allows(...)` — cooldown 600 s, fresh-before-stop 60 s. Pure.
- `ResumeCoordinator` (`SessionResume.swift`) — `deliver` tries
  `socketSend` when `session.canUseSocket` (`peerProtocol == 1` and a
  non-empty path), then PTY hosts. With `hosts: []` and `socketSend`
  swapped for the named-pipe writer it is the Windows resume path
  unchanged: retries at 5 s / 15 s, 10 s verify watch at 1 s polls, nudge
  text `ResumeCoordinator.nudgeText(attempt:)` with a distinct suffix per
  retry (CC dedups identical messages from one sender).

## Phone-driven resume (in scope, phase 2)

`POST /sessions/<pid>/input {"kind":"resume","text":""}` →
`SessionInput.deliver(.resume)` → `continueText()` through the pipe. That
is the Windows "Continue" button; no coordinator needed for a manual tap.
Ships with W10.

## Automatic resume (deferred, with the trigger it needs)

On the Mac, `ResumeService` runs the coordinator when the engine says
quota is available again (`ResumeGate` compares the active account's
fetched-at against the stop). Windows has no engine and no account
liveness signal, so an automatic nudge would be evidence-free — exactly the
2026-09-01 burn-loop `ResumeGate` exists to prevent. Deferred until a
Windows engine exists (`05-custom-api.md`). What the daemon does instead:

- `GET /snapshot` marks stopped sessions: `SessionPanelRow.status` stays the
  record's status, and `progressByPid[pid].phase`/`goal` are as read; add
  nothing new to the models. The feed's last item renders as `.limit` with
  the limit text (`SessionFeed.parse` already does this), and the phone
  shows its Continue button — the manual path above.
- `infinitus-win resume [--pid N]` CLI (W15, S): runs `Transcript.findStopped`
  over live records and `ResumeCoordinator.resume` with the pipe sender,
  `--dry-run` prints the stopped list. Local, on-demand, for the user who
  knows quota is back. No timer.

## Terminal nudge channel (deferred)

`PtyNudge` needs a `PtyHost` that can read the screen (to see "menu
captured", "running") and type. cmux/tmux/herdr are Unix. Windows Terminal
exposes no such CLI; ConPTY requires being the console's creator. Options
recorded for later, none in this plan:

1. `infinitus-win launch -- claude …` — the daemon spawns `claude.exe`
   under its own ConPTY and proxies I/O to the visible terminal; then it
   owns a write handle (keys, menus). Large, changes how the user starts
   sessions.
2. `SendInput`/`WriteConsoleInput` into the Windows Terminal window —
   needs window focus / attached console; fragile, rejected.

Until then every `kind: key` request answers `noSurface`; the phone hides
the key row for `keys: false` hosts (`04-phone.md`).

## Held-for-review interplay (documented, unchanged)

`Transcript.Verdict.waiting` covers "held for approval" — invisible from
the transcript, never re-nudged (a retry would queue duplicates). Same on
Windows; the `held for approval (recipient: uds:\\\\.\\pipe\\LOCAL\\cc-msg-…`
lines seen in Windows transcripts are the sender-side record of that state.
