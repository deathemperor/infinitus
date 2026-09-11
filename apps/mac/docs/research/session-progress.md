# Session progress tracking — brainstorm (2026-09-01)

User: "I only want to look at Infinitus when agents are working, if
Infinitus does a good job at tracking progress of all sessions. If we
use Claude Code for it → consuming user's tokens, it gotta be very
light (obviously with option to turn off). Useful for the wall and
definitely for mobile when AFK."

The reframe this implies: Infinitus's job isn't "which account am I
on" — it's **"are my agents okay, and how far along are they."** The
fleet is plumbing; the sessions are the show. The wall and the phone
are the two surfaces where that show plays.

## Layer 0 — what the transcripts already say, zero tokens

Everything below comes from files we already read (Claude Code's own
session records + transcript tails — the resume mechanism's exact
machinery, `Transcript.lastTurnEntry` generalized). Verified against a
live transcript: timestamps, tool_use names, and per-turn token usage
are in every tail; TodoWrite payloads and summary titles appear when
sessions use them.

Per session, parse the last ~512KB tail into a `SessionProgress`:

- **Identity**: cwd (→ repo name), session title (`type:"summary"`
  entries carry one), kind, pid.
- **Now doing**: the last `tool_use` name + salient input (file path
  basename, command's first word) → "Editing AppModel.swift",
  "Running swift test", "Searching PtyNudge"; or the last assistant
  text's first line when it's talking.
- **Progress — the crown jewel**: the most recent `TodoWrite` payload
  IS a structured progress report the agent maintains about itself:
  `[{content, status, activeForm}]` → "3/7 done · Wiring the
  recorder". No inference, no tokens; agents that use todos get rich
  progress for free.
- **Rhythm**: last-entry timestamp → working/quiet-for; turn duration;
  entries-per-minute as a liveliness signal.
- **Burn**: per-turn `usage` tokens → session token burn, attribution
  to the account it rides.
- **Trouble**: repeated identical tool calls (loop suspicion), a
  `system/api_error` tail (retrying), a limit stop (already detected),
  long busy silence (hung tool).

Status taxonomy for a card: `working` (entries flowing) · `thinking`
(busy, no tool activity yet) · `waiting-input` (Claude Code waiting on
the user — the session record's `waiting` status) · `quiet` (idle N
min) · `retrying` · `stopped-limit` · `done?` (idle after a final
assistant text).

Cost of layer 0: tail reads every ~10s for ~16 sessions — the same IO
class as the resume scanner's 20s sweep. Nothing leaves the machine.

## Layer 1 — cheap inference, still zero tokens

- **Goal line**: first user message of the session (or the summary
  title) ≈ what the session is FOR; show it as the card's subtitle.
- **Progress ratio without todos**: tool-call mix over time (explore →
  edit → test → commit reads as phases); a session that moved from
  Read-heavy to Edit-heavy to Bash-test is "past the middle". Heuristic,
  label it as such (no fake percentages — a phase word: exploring /
  building / verifying / wrapping up).
- **ETA-ish**: none. Fake ETAs destroy trust; show elapsed + phase.

## Layer 2 — Claude-powered narration (optional, off by default)

For the AFK case: a one-line human summary better than tool names —
"Fixing the resume race; tests passing, writing the changelog."

- **Model**: smallest available (Haiku-class), `claude -p` headless
  with a hard cap: ~2–4KB of tail excerpt in, one sentence out.
  ~750–1200 tokens per summary → plan-quota noise, but real; hence:
- **Triggers, strictly**: only while a consumer is LOOKING (wall up,
  mobile app open/Live Activity active — mirrored as a flag), only for
  sessions whose transcript actually changed, at most one summary per
  session per 5 min, and never for the session Infinitus itself rides
  if detectable (self-lineage skip, same as /rc).
- **Account choice**: run on the ACTIVE account (it's the one being
  consumed anyway) — never wake an idle account's 5h window for a
  summary (that's #7's job to do deliberately, not a side effect).
- **Controls**: Engines pane — off (default) / wall-only / wall+mobile;
  a per-day token budget readout ("summaries cost ~N tok today") so the
  cost is visible, not vibes.
- **Privacy**: excerpts go to the same API the session already talks
  to — no new disclosure class; but the MOBILE mirror only ever
  carries the derived one-liners and todo states, never transcript
  bodies.

## Where it shows

- **Wall (the reason it exists)**: when `busy > 0`, the hero zone
  yields to (or splits with) a **session board** — one card per
  working session: repo, goal line, now-doing, todo bar (3/7), elapsed,
  burn, trouble badge. All-dead still wins the hero (nothing matters
  more). Idle fleet + idle sessions → zen dim. This is "only look when
  agents are working" made literal: the wall is boring exactly when
  nothing is happening.
- **Popup**: the sessions popover (brain chip) upgrades from
  pid/cwd/status rows to mini progress rows. Cheap win, same data.
- **Mobile / Live Activity**: the working-sessions Live Activity (#2)
  gets its content solved — active account + "3 agents working · 12/19
  todos · newest: Wiring the recorder". The session board is the
  mobile app's second screen. AFK push: "agent finished / agent stuck"
  from the trouble signals — that's the notification actually worth
  sending.
- **Linux**: same parser in InfinitusCore; the Quickshell panel gains a
  sessions section (parity note — tray reads the same ~/.claude).

## Build order (proposed)

1. `SessionProgress` parser in InfinitusCore + tests (fixtures from real
   transcript shapes) — todos, now-doing, rhythm, trouble.
2. Popup sessions popover upgrade (smallest surface, proves the data).
3. Wall session board (the payoff surface).
4. Panel/Linux parity.
5. Layer 2 narration behind the Engines-pane toggle.
6. Mobile once the companion exists (#9) — the mirror carries
   `SessionProgress` rows from day one.

## Open questions for the user

1. ~~Todo-based progress only appears when agents use TodoWrite — fine,
   or should the phase heuristic (layer 1) fill in always?~~ Shipped
   2026-09-03 as fill-in: the phase word shows only when the tail has
   no TodoWrite report (`SessionProgress.phase`).
2. Is `claude -p` on the plan acceptable for narration, or should
   layer 2 wait for an API-key option (billed, not plan quota)?
3. Wall: session board replaces the hero while working, or splits the
   screen with the account hero?
