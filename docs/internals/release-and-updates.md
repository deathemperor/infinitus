# Release and updates

The rules — the tag, the changelog fold, the `nightly` release edited in place — are in INFINITUS.md's Non-negotiables. This page holds the mechanics behind them.

## Nightly delivery

GitHub delivers the two cron slots (17:17 UTC and the 18:17 UTC retry) hours late on this repository — 2 h 09 on 2026-09-13, over 3 h on 2026-09-14, both nights green — so a watcher waits until at least 4 h past the retry slot before treating a night as missed, and never hand-dispatches with `publish` while a slot may still deliver: two publishes in one night edit the same release, waste rather than breakage.

## Desktop update feeds

Desktop updates follow electron-updater's own GitHub rule (#924): the client's channel is its version's prerelease id (`alpha` for `0.5.0-alpha.N`, `latest` for a plain version, `resolveElectronUpdaterFeed`), the provider offers a release only when the tag's prerelease id equals it, and it downloads `<id>-mac.yml` from that release (`latest-mac.yml` for a plain version), which is why the build publishes on that id (`resolveDesktopPublishChannel`) and the workflow checks for that file. An `alpha` client follows a newer `beta` tag and, through the library's `latest-mac.yml` fallback, the first plain version; a plain version reads `releases/latest` and never sees a prerelease. A release whose tag is not a semver version has no channel: a prerelease client would take it and fail its polls (no manifest) were it the feed's first entry, which is why the `nightly` release must keep its place below the newest versioned tag (its rule is with `nightly` above).

The `infinitus-nightly` track (#1042; Settings › Updates, "Nightly" beside "Release", a switch that goes both ways) cannot use that rule — the GitHub provider takes only semver-tagged releases, and a per-night `v…` tag would be the site's "latest" (`apps/mac/site`'s worker) — so `DesktopUpdates.applyFeedProvider` puts electron-updater on the generic provider at `releases/download/nightly` with channel `infinitus-nightly` (the manifest `infinitus-nightly-mac.yml`, `resolveDesktopPublishChannel`), downgrades on, and back on app-update.yml's provider when the track is left; a nightly build on the release track follows its line's id with downgrades on, since semver ranks `alpha.7` below `alpha.6-infinitus-nightly.…`. On both fork tracks an available update downloads itself (`DesktopUpdates.autoDownloadOnForkChannel`); upstream keeps the download behind a click, and a click that raced a relaunch started over.

## History

History: before the fold, desktops shipped as `v<version>-infinitus.<date>.<run>` prereleases from "Fork desktop release" (channel `infinitus`, manifest `infinitus-mac.yml`: those clients, and `0.5.0-alpha.1`, which still told the updater `infinitus`, can only be updated by hand) and the Mac app from `mac-v<version>` tags with a `native-helper.json` pin.
