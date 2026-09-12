import type { DesktopUpdateChannel } from "@t3tools/contracts";

const NIGHTLY_VERSION_PATTERN = /-nightly\.\d{8}\.\d+$/;

export function isNightlyDesktopVersion(version: string): boolean {
  return NIGHTLY_VERSION_PATTERN.test(version);
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
  return isNightlyDesktopVersion(appVersion) ? "nightly" : "infinitus";
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
    `releases/latest`. Downgrades stay off there (versions only go up).
    Upstream's channels keep upstream's settings. */
export interface ElectronUpdaterFeed {
  readonly channel: string;
  readonly allowPrerelease: boolean;
  readonly allowDowngrade: boolean;
}

const PRERELEASE_ID_PATTERN = /^\d+\.\d+\.\d+-([0-9A-Za-z-]+)/;

export function resolveElectronUpdaterFeed(
  appVersion: string,
  channel: DesktopUpdateChannel,
): ElectronUpdaterFeed {
  if (channel !== "infinitus") {
    const prerelease = channel === "nightly";
    return { channel, allowPrerelease: prerelease, allowDowngrade: prerelease };
  }
  const prereleaseId = PRERELEASE_ID_PATTERN.exec(appVersion)?.[1];
  return prereleaseId === undefined
    ? { channel: "latest", allowPrerelease: false, allowDowngrade: false }
    : { channel: prereleaseId, allowPrerelease: true, allowDowngrade: false };
}
