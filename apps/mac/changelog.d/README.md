# Release-note fragments

One file per PR, any name (`<pr>.md` is the habit), deleted at the release
cut by `node scripts/fold-changelog.mjs <version>`, which folds every line
here plus the `## Unreleased` block of `../CHANGELOG.md` into the new
`## <version>` section. Each non-empty line:

    Surface: One short sentence, what you get and why it matters.

Surface is `Mac`, `Desktop`, `Phone` or `Linux`. Writing the note here
instead of in CHANGELOG.md means two PRs never conflict on the same block.
