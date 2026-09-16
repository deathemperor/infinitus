import type { DesktopUpdateChannel } from "@infinitus/contracts";

/** The version's first prerelease id (`alpha` for `0.5.0-alpha.1`), or
    undefined for a plain version. electron-updater and electron-builder key
    the GitHub feed on it (#924), so every rule here reads it and never a
    substring: `0.5.0-alpha.6-infinitus-nightly.20260913.42` is an `alpha`. */
const PRERELEASE_ID_PATTERN = /^\d+\.\d+\.\d+-([0-9A-Za-z-]+)/;

function resolvePrereleaseId(version: string): string | undefined {
  return PRERELEASE_ID_PATTERN.exec(version)?.[1];
}

/** An upstream build that wears upstream's own brand: a nightly
    (`x.y.z-nightly.<date>.<run>`) or a preview, the maintainers' hand-cut
    test train (upstream #11372). Branding only — the update feed is a
    separate question, and `resolveDefaultDesktopUpdateChannel` below keeps
    upstream's split by asking for a nightly specifically: upstream packages
    a preview with no feed at all. The fork cuts neither, so both arms exist
    here to keep an upstream build merged in from being mistaken for ours. */
export function isNightlyDesktopVersion(version: string): boolean {
  const id = resolvePrereleaseId(version);
  return id === "nightly" || id === "preview";
}

const INFINITUS_NIGHTLY_SUFFIX_PATTERN = /-infinitus-nightly\.\d{8}\.\d+$/;

/** This repo's nightly (#1042): `<VERSION>-infinitus-nightly.<date>.<run>`,
    main built every night onto the rolling `nightly` release. The line's own
    id stays first, so the release track's feed can be read off it. */
export function isInfinitusNightlyDesktopVersion(version: string): boolean {
  return INFINITUS_NIGHTLY_SUFFIX_PATTERN.test(version);
}

/**
 * A build of this repo: everything but an upstream nightly. One product, one
 * version (#823): the desktop's version is the product's (`0.5.0-alpha.N`,
 * from the root `VERSION` file), so the channel is no longer read off a
 * dated `-infinitus.` suffix; the older suffixed builds still count.
 * `latest` is upstream's stable channel and never a default here.
 */
export function isInfinitusDesktopVersion(version: string): boolean {
  return !isNightlyDesktopVersion(version);
}

export function resolveDefaultDesktopUpdateChannel(appVersion: string): DesktopUpdateChannel {
  // The nightly TRACK, not the nightly brand: an upstream preview brands as
  // nightly but follows no feed, so only a true upstream nightly defaults
  // here. Everything else is ours; `latest` is upstream's stable channel and
  // never a default in this repo, which is where we part from upstream.
  if (resolvePrereleaseId(appVersion) === "nightly") return "nightly";
  return isInfinitusNightlyDesktopVersion(appVersion) ? "infinitus-nightly" : "infinitus";
}

/**
 * The channel a build actually follows. An Infinitus build whose settings still
 * carry the stable channel — the default a pre-`infinitus` fork build persisted —
 * would otherwise never see another fork release, since the fork publishes only
 * prereleases tagged on the `infinitus` channel.
 */
export function resolveEffectiveDesktopUpdateChannel(
  appVersion: string,
  storedChannel: DesktopUpdateChannel,
): DesktopUpdateChannel {
  return isInfinitusDesktopVersion(appVersion) && storedChannel === "latest"
    ? "infinitus"
    : storedChannel;
}

/** What electron-updater is told for a build on a track (#924). Its GitHub
    provider takes a release only when the tag's first prerelease id equals
    the channel it was told, and names the manifest after that id
    (`<id>-mac.yml`, `latest-mac.yml` for a plain version). So on the
    `infinitus` track the channel is the version's own prerelease id, never
    the track's name: `0.5.0-alpha.1` follows `alpha`, a plain `0.5.0` reads
    `releases/latest`. Downgrades stay off there (versions only go up) — except
    for a nightly build switching back: its line's newest release compares
    lower in semver. The `infinitus-nightly` track reads the rolling `nightly`
    release through the generic provider (`DesktopUpdates` sets the URL;
    #1042): one manifest name whatever the version, and downgrades on, since
    a VERSION bump lands the same night's build below the one running.
    Upstream's channels keep upstream's settings. */
export interface ElectronUpdaterFeed {
  readonly channel: string;
  readonly allowPrerelease: boolean;
  readonly allowDowngrade: boolean;
}

export function resolveElectronUpdaterFeed(
  appVersion: string,
  channel: DesktopUpdateChannel,
): ElectronUpdaterFeed {
  if (channel === "infinitus-nightly") {
    return { channel, allowPrerelease: true, allowDowngrade: true };
  }
  if (channel !== "infinitus") {
    const prerelease = channel === "nightly";
    return { channel, allowPrerelease: prerelease, allowDowngrade: prerelease };
  }
  const nightlyBuild = isInfinitusNightlyDesktopVersion(appVersion);
  const prereleaseId = resolvePrereleaseId(
    nightlyBuild ? appVersion.replace(INFINITUS_NIGHTLY_SUFFIX_PATTERN, "") : appVersion,
  );
  return prereleaseId === undefined
    ? { channel: "latest", allowPrerelease: false, allowDowngrade: nightlyBuild }
    : { channel: prereleaseId, allowPrerelease: true, allowDowngrade: nightlyBuild };
}
