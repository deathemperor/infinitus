# Infinitus fork — rules on top of AGENTS.md

This `main` is a fork of [T3 Code](https://github.com/pingdotgg/t3code) that
drives the Infinitus engine. AGENTS.md (upstream's guide) applies in full;
this file adds the fork's own rules. Plan and history: issue #555.

## Non-negotiables
- **Never an upstream PR.** Upstream is merged in, not contributed to. Do not
  open pull requests, issues or discussions on `pingdotgg/t3code` from this
  work.
- **One API.** The fork talks to Infinitus only over its control socket
  (`ControlProtocol`: one JSON line each way, `infinitusctl manifest` lists
  the commands) and the mirror HTTP routes — the same wire the phone and the
  Linux tray use (inventory: issue #553). Anything missing becomes a new
  route on the `native` branch, never a second protocol or a read of the
  native app's files.
- **Upstream merges daily, our history never rebased.** `git fetch upstream
  && git merge upstream/main` on a branch, PR to `main`. Our code lives in
  new files, new routes, new settings sections; edits to upstream files stay
  at registration points so merges stay small. The list of upstream files we
  edit on purpose is in "Registration points" below — keep it current.
- **`native` is the Swift app.** Today's native Infinitus (menu bar,
  engines, team, tunnels, mirror API, control socket, PTY host, Linux tray)
  lives on the `native` branch with its own CLAUDE.md, CI and releases.
  Never merge `main` into a native branch or `native` into `main` (unrelated
  histories).
- **Fork releases are GitHub prereleases with their own tag scheme.**
  Installed native apps poll `releases/latest` and the `nightly` tag; those
  stay native forever. Never publish a fork release as latest, never tag
  `nightly` from `main`.
- **PR-only main** (ruleset "main via pull requests"): required checks are
  T3's CI jobs Check, Test, Test Server 1–3. `gh pr create --base main`,
  `gh pr merge --squash --auto`. Every commit carries
  `Co-Authored-By: Claude Code <noreply@anthropic.com>`.
- **Never install anything on the developer's Mac** (toolchains, brew,
  Xcode components, Docker). `vp i` inside the worktree is fine.
- Secrets travel over stdin, never argv; shown masked only.
- Todos and research notes go to GitHub issues, never to files in the tree.

## Registration points (upstream files we edit on purpose)
- `CLAUDE.md` — adds `@INFINITUS.md`.
- `README.md` — the fork notice at the top.
- `.github/workflows/ci.yml` — `runs-on` swapped from Blacksmith runners to
  GitHub-hosted ones, the Blacksmith apt-mirror line dropped, timeouts
  widened. Re-apply after every upstream merge if the merge reintroduces
  `blacksmith-`.
- Upstream workflows that deploy or publish (Release, Deploy T3 Connect
  relay, Forward to Cursor hygiene, Mobile EAS Preview/Production, Publish
  AUR, Issue Labels, Desktop macOS Preview, Web Preview, Mobile Showcase
  Screenshots, Thread Transfer Report) are disabled in the repository's
  Actions settings, not deleted, so merges stay clean.

## Fork-only files
- `.github/workflows/native-nightly-dispatch.yml` — cron dispatcher for the
  `native` branch's nightly jobs (schedules run only from the default
  branch).
