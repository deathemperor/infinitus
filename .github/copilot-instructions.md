# Infinitus — review instructions

Infinitus is a native macOS menu bar app (Swift, SwiftUI + AppKit) with an
iOS companion, a CLI (`infinitusctl`), and a cross-platform core
(InfinitusCore). Account policy engines such as cswap are adapters behind
`AccountEngine`; the app never depends on one engine existing.

## How to review

- Review only the lines the pull request changed. Older code in the same
  file is not a finding, and do not ask for cleanup outside the PR's scope.
- Post each finding as one inline comment on the smallest relevant range:
  name the rule, say what the code should do instead, stop. Prefer a
  `suggestion` block when the fix is a few lines.
- Report a finding only when the diff makes the violation clear. Style
  preferences, comment wording, and import order are not findings.
- Every PR should do one thing. If the description says "also", say so
  once in the summary and do not review the second concern in detail.
- Do not comment on test files unless a test asserts the wrong behavior.
- When there are no findings, the whole review body is exactly `All clear`.

## Project rules a diff can violate

- **Engine isolation.** Every engine touchpoint is a `cswap … --json`
  subprocess through `Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift`.
  Flag any read of `~/.claude-swap-backup/*` or any parsing of engine
  internals. Reading Claude Code's own files (`~/.claude/settings.json`,
  `~/.claude/sessions/*`, `~/.claude/projects/*/*.jsonl`) is fine.
- **No cswap dependency outside the adapter.** Flag a feature, data
  format, CLI command, or publisher that only works when cswap is
  installed, and any new cswap subcommand meant to ship app features.
- **Gate UI on capabilities, never on engine identity.** Flag
  `if engine.id == "cswap"`-style checks in UI; the check belongs on the
  fleet's `capabilities`.
- **Account policy lives in the engines.** Flag app-side code that
  re-implements auto-swap, pick-first, or account ordering instead of
  setting the engine's own knob.
- **Secrets travel over stdin, never argv**, and are shown masked. Flag a
  token, webhook URL, or key passed as a command-line argument, logged,
  or rendered unmasked.
- **Bundle and service ids stay under `run.infinitus`.** Flag any new or
  changed bundle id, keychain service, socket, or notification id outside
  that prefix.
- **Dev instances must set `INFINITUS_CONTROL_SOCKET`.** Flag a script or
  test that launches a second app instance without it.
- **Release notes are one line per feature.** Flag multi-sentence
  CHANGELOG bullets.
- **Todos and research notes go to GitHub issues.** Flag a new TODO or
  research markdown file; `docs/TODO.md` is the shipped log only.
- **Usage-cost figures are estimates.** Flag copy that presents them as
  billing truth.

Swift-specific rules are in `instructions/swift.instructions.md`.
