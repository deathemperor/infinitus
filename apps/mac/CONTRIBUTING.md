# Contributing

## Developer setup

`./make-app.sh && open Infinitus.app` builds and launches the app;
`swift test` runs the unit tests; `./dev.sh` is the entr-driven dev loop.
`CLAUDE.md` holds the project rules and the hard-won facts every change
has to respect.

## Read this first

Infinitus is a small, opinionated project and is not actively taking
feature contributions. You can open a bug report or a PR, but expect a
small fix to be far more welcome than a new feature.

Feature ideas belong in
[Ideas discussions](https://github.com/deathemperor/infinitus/discussions/categories/ideas),
not issues.

PRs are automatically labeled with a `vouch:*` trust status and a
`size:*` diff size. External contributors get `vouch:unvouched` until
added to [.github/VOUCHED.td](.github/VOUCHED.td).

## Most likely to be accepted

- Small, focused bug fixes.
- Reliability and performance fixes that keep idle CPU near 0%.
- Tightly scoped maintenance that does not change the project's direction.

## Least likely to be accepted

- Large PRs or drive-by feature work.
- Anything that ties the app to one account engine (cswap is one adapter
  among several, forever).
- Rewrites, reformatting, or "improvements" to code the PR does not need
  to touch.

## If you still want to open a PR

- Keep it small and explain exactly what changed and why.
- One concern per PR. If the description says "also", split it.
- UI changes need before/after screenshots; motion needs a short video.
- `swift test` must pass and the CI e2e perf gate must stay green.
- Every release note line is one short sentence.
