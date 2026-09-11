# The smart engine — reset battle plans (#7, planned 2026-09-01)

User's framing: "if we have a smart engine to trigger its reset time
based on usage intelligently gathered of current work, we'll be able
to use the same account's 2 sessions back to back… => this will be a
big 'Infinitus' if it works. feel free to suggest any mechanism…
including using claude itself inside the engine to strategize the
nudges and all the reset battle plan."

Planned last, as instructed, with the rest of the queue shipped.

## The physics

A 5h window starts on the FIRST request after the previous window
expired — it is not anchored to clock hours. That makes the start
time a controllable input: a single tiny request on an idle account
starts its clock. Everything else follows from choosing those start
times well.

The prize, concretely: an 8-hour evening sprint on one account today
costs a mid-sprint switch (or a stall) when the 5h window binds. If
that account's window had been ignited ~3h before the sprint began,
the window would bind and RESET mid-sprint — the sprint rides two
full back-to-back sessions of the SAME account. Fewer switches, other
accounts' weekly headroom preserved, /rc churn avoided.

## The primitive we already have

`cswap run <num> -- …` runs one command as a stored account without
switching the fleet (per-terminal, experimental). An **igniter** is:

    cswap run <num> -- claude -p "." --max-turns 1

— one ~1K-token request. Cost: those tokens (weekly-counted, noise).
Risk if misjudged: none in tokens — an unused window expires free;
the only thing wasted is the opportunity to have started it at a
better instant. Engine isolation holds: ignition is a cswap verb, no
engine internals touched.

## What the strategist knows (all already collected)

- **usage-history JSONL**: per-account 5h/7d/scoped pct + resets over
  time → real window-start instants, per-window utilization, and the
  user's daily work rhythm (when sprints actually happen).
- **SessionProgress** (#13): live todo backlog, activity rhythm,
  goal lines → is a sprint in progress, and does it look long?
- **Engine state**: active account, candidates, weekly headroom,
  auto-switch config (threshold/cooldown/strategy).

## Architecture

Three layers, shipped in order; each is useful without the next.

### 1. Window telemetry (deterministic, InfinitusCore)
Extend UsageHistory/WasteMath to 5h windows: reconstruct each window
(start, end, peak pct) from samples. Surfaces: per-account "window
utilization" stat in the Utilization pane; the day's window map as a
timeline strip. This is also the planner's training data and the
simulator's ground truth.

### 2. The planner (deterministic, InfinitusCore `WindowPlanner`)
Inputs: fleet snapshot + live SessionProgress + window telemetry.
Core decision, evaluated each poll:

    if busy sessions exist
       and active's binding window will bind within H hours
       and the best candidate's 5h clock is cold
    → recommendation: ignite candidate now, so its first window is
      partly spent by the time the switch lands, and its SECOND
      window begins mid-sprint.

Plus the sprint-chaining rule (same-account back-to-back): if
projected sprint length > remaining window + idle-gap tolerance,
compute the ignition instant that lands the reset inside the sprint;
if that instant is already past, fall back to rotation as today.
Output is a **battle plan**: ordered (instant, action, why) steps —
ignite N at T, expect switch to N at T', expect N's reset at T''.
Actions are only ever: ignite (cswap run), switch (existing), nudge
(existing resume machinery). Plan displayed before it runs.

### 3. Claude the strategist (optional, off by default)
Same posture as #13 narration: a Haiku-class `claude -p` call gets
the day's window map + backlog summary and writes/adjusts the plan as
JSON (validated against layer 2's action vocabulary — the model
proposes, deterministic code disposes). Budgeted, only while plans
are enabled, riding the active account. Layer 2 works without it;
this layer earns its keep on messy days (mixed sprints, partial
fleets, human interruptions).

## Safety rails

- **Plans are visible and cancellable**: a Battle Plan card (popup +
  wall rail) shows the next steps and a cancel; every executed step
  lands in the event log.
- **Never ignite more than one account per horizon**, never ignite an
  account whose weekly/scoped headroom is the fleet's last reserve.
- **Auto-switch stays the safety net**: the planner acts before
  limits; `cswap auto` still catches everything the plan missed.
  Planner disabled ⇒ exactly today's behavior.
- Ignition uses `--max-turns 1` and a fixed prompt; its cost is shown
  honestly in the Utilization pane (estimates, never billing truth).

## Verification path (before any real ignition)

1. **Replay simulator** in the playground: run WindowPlanner against
   recorded usage-history days — "yesterday, this plan would have
   saved N switches and M stalled minutes" — pure math, zero risk.
2. Manual mode first: the plan card shows "ignite now?" as a button
   (user-triggered `cswap run` behind a confirm), auto-execution
   ships only after the simulator + manual phase look right.
3. Auto mode behind an Engines-pane toggle, off by default.

## MVP cut

1. 5h window telemetry + Utilization surfacing (layer 1).
2. WindowPlanner + replay simulator + playground scenario (layer 2,
   compute-only).
3. Battle Plan card with manual ignite (confirm-gated).
4. Auto-execution toggle.
5. Claude strategist (layer 3) last, behind its own toggle.

## Status and decisions (2026-09-03, user: "go with your suggestions")

Shipped: layer 1 (WindowTelemetry), layer 2 (WindowPlanner + replay +
burn rate; Utilization pane dry run), MVP step 3 (live plan line in
the popup, two-tap confirm-gated Ignite; `infinitusctl plan` /
`ignite`). Ignition is an engine capability (`.ignite`,
`AccountEngine.ignite`): cswap implements it with `cswap run`; the
proxy fleet has no "one request as credential X" verb and its Claude
Code cloaking lives in its executor, so nothing app-side can imitate
it safely — the button is hidden there until upstream grows a verb
(candidate PR, after #5434).

Decisions, from the honest assessment:
- **Manual stays the mode.** The auto-execution toggle is parked, and
  if it ever ships it belongs engine-side (account policy lives in the
  engines) — an upstream `cswap ignite` verb plus a scheduler knob,
  not the app running it.
- **Layer 3 (Claude strategist) is dropped.** The decision is
  low-dimensional and deterministic; an LLM would add cost, latency
  and nondeterminism to a dozen lines, and be hard to verify.
- **Replay before more investment.** Samples now carry the active
  account; after a week the Utilization pane's replay says how many
  switches actually landed on cold clocks. That number decides
  whether the planner earns more work.
- **Window-age guard.** The planner only lands on a window (ignited or
  already ticking) with at least `minRemainingAtSwitch` (90 min) left
  at the projected bind — an ignited window that aged past that
  because the bind came late gives minutes then a stall, worse than a
  cold clock. Candidates that resets before the bind count as fresh.
- The prize is narrower than the framing: ignition shifts timing, it
  never adds capacity, so it does nothing for the all-dead case. The
  win is fewer mid-sprint switches and less resume-nudge churn on
  long sprints.

## Open questions (user)

1. Idle-gap tolerance: chaining two windows back-to-back on one
   account can leave a short stall between bind and reset — how many
   minutes of stall are acceptable before rotation is preferred?
2. Is `cswap run`'s [EXPERIMENTAL] label trustworthy enough for the
   igniter, or should ignition ask the engine author for a dedicated
   `cswap ignite <num>` verb (upstream PR)?
3. Does the planner get to ignite while you're AFK (ties into mobile
   remote-control approvals), or only while the Mac is in use?
