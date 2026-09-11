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
