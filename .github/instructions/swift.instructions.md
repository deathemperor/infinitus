---
applyTo: "**/*.swift"
---

# Swift and SwiftUI review rules

Apply these to changed lines only. Each one records a bug that already
cost a day; the reasoning is in `CLAUDE.md` under "Hard-won facts".

## Performance (idle CPU with the pop-out open must stay near 0%)

- Continuous motion goes through Core Animation on a `LayerEffect` host
  (CAAnimation, CAEmitterLayer). Flag a `TimelineView`, a
  `repeatForever` `.animation`, or a timer-driven `@State` tick that
  repaints SwiftUI every frame.
- Never put `.contentTransition(.numericText())` on a value that changes
  every second (countdowns, clocks): it grows the glyph cache for as long
  as it ticks.
- A window that is ordered out must detach its hosting controller on
  close and reuse the `NSWindow`; flag a close path that leaves SwiftUI
  content mounted.

## Layout and windows

- `NSPopover` measures content once: a wholesale content swap must go
  through `withAnimation` so it re-measures. Flag close/reopen used to
  resize a popover.
- Popup scaling is `PopupScale` (fixedSize → measure → scaleEffect +
  matching frame). Flag measurement without `fixedSize`, which feeds the
  scaled width back in.
- The pop-out window must not let `NSHostingView` size it; `PinnedRoot`
  reports its fixedSize geometry and `fitPinned` applies it. Flag a
  `setContentSize` driven by the hosting view's intrinsic size.
- In a `VStack` of mixed text and gauge rows under two-axis `fixedSize`,
  every row needs its own `.fixedSize()`.
- A `GridRow` cannot wear a modifier (it collapses to one cell); put the
  modifier on a `Group` inside the row. Spanning cells need
  `.frame(maxWidth: .infinity)` + `.gridCellUnsizedAxes(.horizontal)`.
- Glass: `NSGlassEffectView` stays active when the window resigns key.
  Flag a focus-swap that toggles it. `CABackdropLayer` does not work
  inside `NSPopover` windows.

## Engines and control

- Engine calls go through `CswapCLI` as `cswap … --json` subprocesses.
  Flag direct file reads of engine state.
- Every engine is an `AccountEngine` yielding `EngineFleet`s; `AppModel`
  is a facade over the primary fleet. Flag new engine-specific branches in
  shared UI; gate on `capabilities`.
- Control-socket commands are declared in `ControlProtocol`; a new
  `ControlServer` case needs the matching `ControlCommand` entry with its
  `effect` so `infinitusctl` and the MCP surface stay in sync.

## Build and process hygiene

- `swift build --product X`, one `--product` per invocation; with two,
  SwiftPM builds only the last. Flag scripts that pass two.
- Never `cp` over a running signed binary; `pkill` first.
- Debug binaries are codesigned with identifier `run.infinitus` so the
  keychain ACL grant sticks; flag a dev script that signs with another id.
- `Foundation.Process` is unavailable on iOS; flag its use in
  InfinitusCore code that the phone target compiles.

## Style

- Surgical diffs: flag reformatting, renamed locals, or moved code that
  the PR's purpose does not need.
- No speculative abstractions: flag a protocol or generic introduced for
  a single conformer.
- Comments describe how a thing is used and move with the code.
