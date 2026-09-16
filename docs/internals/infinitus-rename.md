# The identifier rename

Issue #1368 (user ruling 2026-09-16) extends the product name to identifiers. Slice A made every user-facing string say Infinitus (`PRODUCT_NAME`, `CONNECT_NAME`); slice B renamed the relay's fork-owned infrastructure names; slice C is `scripts/infinitus-rename.ts`, one idempotent table of the identifiers the fork owns outright, so the rename is a script run — and so every upstream sync re-runs it.

## What the table renames, and why only that

The table holds the "safe to rename outright" set of the issue's compatibility checklist: names nothing outside this tree persists or reads. The workspace package scope (`@t3tools/*`, private), the Effect service tags rooted at `t3/`, the CSS custom properties and Tailwind font utilities (`--t3-*`, `font-t3-*`), the wordmark components and the Connect surfaces (`T3Wordmark`, `T3Connect*`, `useT3ConnectAuthPrompt`, files included). The test beside the script proves the table is idempotent (no entry's output matches any entry's pattern) and that the compat-read identifiers pass through untouched.

Everything a user's disk, an installed unit, a shipped build or an external service holds stays out of the table on purpose, because a blind rewrite there breaks an existing install: `T3CODE_*` / `T3_*` env vars (read sites take the new name with the old as fallback), `t3code:` localStorage keys and the two IndexedDB databases (migrate on read: `uiStateStore.ts` already has the legacy-key chain to extend), the `t3` binary and its release archive names (slice D: publish both names for a window), the `t3-code` MCP server id (slice E: persisted in users' provider configs, needs a legacy read and a cleanup of the stale entry), the launchd / systemd unit names, the `t3code` URL scheme, the `t3-env:` issuer and `t3-relay-dpop-access+jwt` typ, `/.well-known/t3/environment`, the Android notification tags, the Axiom dataset names (their tokens are baked into builds), the Expo slug and the upstream-variant mobile bundle ids and `modules/t3-*` native module ids. Each of those is its own slice with a legacy read at every site.

## Applying it

The rename lands in one PR, in a quiet window: the dry run touches ~2,450 files, so every open branch conflicts with it, and the seven live feature branches are merged or rebased first. Then `node scripts/infinitus-rename.ts`, `pnpm install` (the lockfile's `workspace:*` specifiers carry the new scope), the typechecks and the test suites, and `node scripts/infinitus-rename.ts --check` must pass — it is the guard from then on: it fails while any old identifier is in the tree.

## The sync rule

Once the rename has landed, an upstream merge would conflict on every renamed line. The rule that keeps merges small: on each sync, branch from `upstream/main`, run the script THERE (`git show main:scripts/infinitus-rename.ts` — the script is the fork's, upstream has none), commit, then merge that branch into the sync branch. Both sides then carry the same names and the merge's conflicts collapse to real changes. `upstream-sync.yml` does exactly this once `--check` passes on `main`; before that it merges upstream unrenamed, as today. Never "take upstream's file and re-run the script": that drops the fork's registration-point edits in that file.
