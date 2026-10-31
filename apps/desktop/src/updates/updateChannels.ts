import type { DesktopUpdateChannel } from "@infinitus/contracts";

/** The version's first prerelease id (`alpha` for `0.5.0-alpha.1`), or
    undefined for a plain version. electron-updater and electron-builder key
    the GitHub feed on it (#924), so every rule here reads it and never a
    substring: `0.5.0-alpha.6-infinitus-nightly.20260913.42` is an `alpha`. */
const PRERELEASE_ID_PATTERN = /^\d+\.\d+\.\d+-([0-9A-Za-z-]+)/;

function resolvePrereleaseId(version: string): string | undefined {
  return PRERELEASE_ID_PATTERN.exec(version)?.[1];
}

/** An upstream build that wears upstream's brand: a nightly or a preview (upstream
    #11372). Branding only; the feed is separate, and `resolveDefaultDesktopUpdateChannel`
    asks for a nightly specifically since upstream packages a preview with no feed. The
    fork cuts neither; the arms keep a merged upstream build from passing as ours. */
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
 * A build of this repo: everything but an upstream nightly. The desktop's version is the
 * product's (#823), so the channel is not read off a dated `-infinitus.` suffix, though
 * older suffixed builds still count. `latest` is never a default here.
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

/** What electron-updater is told for a build on a track (#924). Its GitHub provider takes
    a release only when the tag's first prerelease id equals the channel, so `infinitus`
    uses the version's own id, with downgrades off. `infinitus-nightly` reads the rolling
    `nightly` release via the generic provider with downgrades on (#1042). */
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
    return { channel, allowPrerelease: channel === "nightly", allowDowngrade: false };
  }
  const nightlyBuild = isInfinitusNightlyDesktopVersion(appVersion);
  const prereleaseId = resolvePrereleaseId(
    nightlyBuild ? appVersion.replace(INFINITUS_NIGHTLY_SUFFIX_PATTERN, "") : appVersion,
  );
  return prereleaseId === undefined
    ? { channel: "latest", allowPrerelease: false, allowDowngrade: nightlyBuild }
    : { channel: prereleaseId, allowPrerelease: true, allowDowngrade: nightlyBuild };
}
