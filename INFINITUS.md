# Infinitus fork — rules on top of AGENTS.md

This `main` is a fork of [T3 Code](https://github.com/pingdotgg/t3code) that
drives the Infinitus engine. AGENTS.md (upstream's guide) applies in full;
this file adds the fork's own rules. Plan and history: issue #555.
Unification (#823, user ruling 2026-09-11): the product is one name,
Infinitus — no user-facing "fork", "native" or "T3 Code" anywhere; the
Swift app lives in `main` as `apps/mac`; one version `0.5.0-alpha.N`
ships everything from one release. "Fork" and "native" below are
contributor shorthand for this TypeScript tree and the Swift app.

## Non-negotiables

- **Never an upstream PR.** Upstream is merged in, not contributed to. Do not
  open pull requests, issues or discussions on `pingdotgg/t3code` from this
  work.
- **One API.** The fork talks to Infinitus only over its control socket
  (`ControlProtocol`: one JSON line each way; `infinitusctl manifest` is the
  runtime command table — its reply shapes are prose, so reply schemas are
  hand-written in `packages/contracts` and validated at the boundary);
  the phone reaches the Mac through the desktop (inventory: issue #553;
  the Mac's mirror HTTP server left with #1041). Anything missing becomes a new
  route on the `native` branch, never a second protocol or a read of the
  native app's files.
- **Upstream merges daily, our history never rebased.** `git fetch upstream
&& git merge upstream/main` on a branch, PR to `main`. Our code lives in
  new files, new routes, new settings sections; edits to upstream files stay
  at registration points so merges stay small. The list of upstream files we
  edit on purpose is `docs/internals/fork-registration-points.md` — keep it current.
  Identifiers are renamed by `scripts/infinitus-rename.ts` (#1368 C), run on
  upstream's side of each sync once it has landed: `docs/internals/infinitus-rename.md`.
  Expected on every sync (#823 layer 3): upstream's tests assume a plain
  `x.y.z` is a `latest` build titled "(Alpha)"; here every non-nightly
  version is an `infinitus` build, so their fixture expectations in
  `scripts/build-desktop-artifact.test.ts` (0.0.17 icons and brand, DMG
  background; the publish config follows the version's prerelease id and
  matches upstream's expectation), `apps/desktop/src/settings/DesktopAppSettings.test.ts`
  (default channel), `apps/desktop/src/app/DesktopEnvironment.test.ts`,
  `DesktopAppIdentity.test.ts` and `DesktopPreReadyPlatform.test.ts` (plain
  title, no stage suffix) and `apps/desktop/src/updates/DesktopUpdates.test.ts`
  (upstream-channel tests start on a nightly feed via the harness `settings`
  option; the harness's `resourcesPath` option and the feed-swap test are
  the fork's, #1042; `DesktopShellEnvironment.test.ts`'s harness takes an
  `existingPaths` fake filesystem for the known-CLI-dirs fallback, #1078), and
  `apps/desktop/src/updates/releaseNotes.test.ts` (the channel argument: the
  notes are filtered by `resolveDefaultDesktopUpdateChannel`, which never
  answers `latest` here)
  are re-flipped to `infinitus` after each merge, never the rule.
  An upstream migration whose number collides with the fork's own
  (`051`–`057`, `059`, `061` and `062`, #806 onward) is renumbered after them in the merge
  (`Migrations.ts` and the file; upstream's `051_ProjectionThreadMessageContext`
  is the fork's `058`, its `052_ProjectionThreadTitleState` the fork's
  `061`), so an existing fork database never skips it. Upstream commits
  `.pnpm-store/v11/index.db` (#11265) and rewrites it on every install; the
  fork ignores the file and drops it from the merge (`git rm --cached`), so
  each sync meets it as a modify/delete conflict resolved the same way.
- **`apps/mac` is the Swift app** (#823 layer 2, 2026-09-12). Today's
  native Infinitus (menu bar, engines, tunnels, mirror API, control
  socket, Linux tray) lives in `apps/mac` with its own CLAUDE.md
  (read it when working there), its own CHANGELOG/VERSION, path-filtered
  CI jobs (`mac-*` in ci.yml) and its own workflow
  (`mac-linux-sanitize.yml`; releases are `infinitus-release.yml` and the
  nightly `infinitus-nightly.yml`, below).
  It came in as a subtree
  (`git subtree add`) from the frozen `native` branch, history included
  (the merge's second parent). Its dev loop is unchanged: `cd apps/mac && ./make-app.sh`,
  `swift test`, `/bin/sh tools/e2e.sh`. infinitus.run is `apps/mac/site`,
  deployed by hand with wrangler from that directory.
- **One release (#823 layer 3).** A `v<version>` tag on `main` runs `.github/workflows/infinitus-release.yml` (upstream's `release.yml` stays disabled, hence the name; its CONTENT is still upstream's, taken whole at every sync, but the sync's runner swap rewrites it like every other workflow — a merge that takes upstream's file wholesale and skips the swap silently reintroduces Blacksmith runners): the `mac` job builds, signs, notarizes and staples both Swift bundles on `macos-26`; `desktop` nests that run's `Infinitus-Menu-Bar-<v>.zip` and builds the DMG with `--build-version "$VERSION"`; `linux` builds the tray; `publish` creates the one GitHub release — DMG, zip, blockmaps, the updater manifest, both menu bar zips, the Linux binaries — titled `Infinitus <version>`, notes from the `## <version>` section of `apps/mac/CHANGELOG.md` (no section, no release; a PR writes its note as a fragment in `apps/mac/changelog.d/` — `Surface: sentence` per line — and the cut runs `node scripts/fold-changelog.mjs <version>` to fold the fragments and `## Unreleased` into that section. The script unlinks every fragment it folds, so those deletions belong in the cut commit itself: the tag must point at a tree whose `changelog.d/` holds only its README, which the `notes` job checks before anything is built), `--prerelease` iff the version carries a prerelease tag. The tag must equal `v$(cat VERSION)`. `workflow_dispatch` is the dry run (artifacts, nothing published). The site's installer reads `releases/latest` and the `nightly` tag (the menu bar app's own poll left with its About pane, #1237): `latest` becomes the one-app release with the first plain version; `nightly` is `infinitus-nightly.yml`'s rolling build of the whole product (#1042): the same build jobs, called (`workflow_call`) every night at 17:17 UTC with `<VERSION>-infinitus-nightly.<yyyymmdd>.<run>` written over `VERSION` in the job, published by the caller — one release created once and only edited in place (tag re-pointed, assets clobbered, older nights' versioned assets removed, title edited), never deleted and recreated: the desktop updater takes the first entry of `releases.atom`, an edited `nightly` keeps its place below the newest versioned tag, a recreated one would not (#924). A dispatch of the nightly workflow is a dry run unless its `publish` input is set from `main`. GitHub delivers the cron slots hours late here: wait ≥ 4 h past the slot before calling a night missed, and never hand-dispatch with `publish` while a slot may still deliver (#1258). The `infinitus` track name lives only in the desktop's settings and UI. Feed mechanics and history: `docs/internals/release-and-updates.md`.
- **One version (#823 layer 3).** The root `VERSION` file (one line,
  `0.5.0-alpha.N`) is the only place the product version is written:
  `apps/mac/make-app.sh` reads it for `CFBundleShortVersionString`,
  `infinitus-release.yml` passes it as `--build-version`, and
  `apps/mobile/app.config.ts` carries it as `extra.productVersion` for the
  phone's Settings (the store's `version` stays a dotted-integer marketing
  version, and cannot go down).
  `apps/desktop/package.json`'s version is upstream's and never edited. The
  `infinitus` track is internal and follows from the version, not a flag:
  every version that is not an upstream nightly (first prerelease id
  `nightly`) brands as `infinitus`; one carrying the nightly suffix
  `-infinitus-nightly.<date>.<run>` (#1042; the line's id stays first,
  `0.5.0-alpha.7-infinitus-nightly.20260913.42`) defaults to the
  `infinitus-nightly` track with the same brand and a plain title, every
  other one to `infinitus` (`resolveDesktopUpdateChannel`,
  `resolveDefaultDesktopUpdateChannel`,
  `resolveWebAssetBrandForPackageVersion`; all read the first prerelease
  id, never the `-nightly.` substring the suffix carries too). Upstream's `latest` track is
  never a default here; a persisted `latest` resolves to `infinitus`. The
  feed a build follows is a separate thing, above.
- **PR-only main** (ruleset "main via pull requests"): required checks are
  T3's CI jobs Check, Test, Test Server 1–3. `gh pr create --base main`,
  `gh pr merge --squash --auto`. Every commit carries a
  `Co-Authored-By: Claude … <noreply@anthropic.com>` trailer naming the
  model that did the work (the harness supplies the exact name). A session
  working for the fork's owner (deathemperor) opens the PR and arms the
  merge without asking — standing consent, user ruling 2026-09-15; for
  anyone else AGENTS.md's rule stands: no PR unless asked.
- **Worktrees share one clone's `refs/remotes/origin`.** Several sessions
  work in worktrees of the same clone, so `git fetch && git merge origin/main`
  can merge a tip another session fetched moments earlier and land a branch
  that silently misses commits already on main (#1092 missed #1091 this way,
  with a clean-looking stat). After every merge of main and before arming
  auto-merge: `git fetch origin main && git merge-base --is-ancestor
origin/main HEAD || echo STALE`. A PR whose checks are green but whose
  mergeability sits at UNKNOWN for a quarter hour is GitHub's, not ours:
  `gh pr close` then `gh pr reopen` recomputes it and re-fires the PR event
  (auto-merge drops on reopen; arm it again). Never push empty commits for
  either. The stash stack is shared the same way, so **`git stash` is
  off-limits in this repo** (ruling 2026-09-14): two sessions' push/pop pairs
  interleaved and each popped the other's work — one baseline run swapped a
  #1213 edit for another lane's uncommitted feature, recovered only because
  the tree was diffed to a patch before anything else touched it. Commit to
  the branch, or use a scratch worktree, for a baseline.
- **Never install anything on the developer's Mac** (toolchains, brew,
  Xcode components, Docker). `vp i` inside the worktree is fine.
- Secrets travel over stdin, never argv; shown masked only.
- Todos and research notes go to GitHub issues, never to files in the tree.

## Registration points and fork-only files

The list of upstream files the fork edits on purpose — one bullet per
file, what the edit is — is `docs/internals/fork-registration-points.md`;
the files that exist only in the fork are described in
`docs/internals/fork-only-files.md`. Both are the merge map: read the
first before touching an upstream file, and add a bullet when you edit a
new one or add a fork-owned file. Feature narratives belong in a
`docs/internals/<feature>.md` page, one line in those ledgers pointing at
it, never a paragraph in this file, which every session loads whole.
`scripts/infinitus-md-size.test.ts` fails the build once this file passes
16 KB (#1339).
