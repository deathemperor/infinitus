import type { DesktopUpdateChannel } from "@t3tools/contracts";

const NIGHTLY_VERSION_PATTERN = /-nightly\.\d{8}\.\d+$/;
const INFINITUS_VERSION_PATTERN = /-infinitus\.\d{8}\.\d+$/;

export function isNightlyDesktopVersion(version: string): boolean {
  return NIGHTLY_VERSION_PATTERN.test(version);
}

/** The fork's own desktop builds, published as prereleases on the `infinitus` channel. */
export function isInfinitusDesktopVersion(version: string): boolean {
  return INFINITUS_VERSION_PATTERN.test(version);
}

export function resolveDefaultDesktopUpdateChannel(appVersion: string): DesktopUpdateChannel {
  if (isInfinitusDesktopVersion(appVersion)) {
    return "infinitus";
  }
  return isNightlyDesktopVersion(appVersion) ? "nightly" : "latest";
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
