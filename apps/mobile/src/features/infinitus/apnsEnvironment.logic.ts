/** Which APNs gateway a device token belongs to, read off the app's embedded
    provisioning profile (#572): a development-signed build's tokens are only
    valid at the sandbox gateway, and declaring the wrong one earns the Mac a
    `BadDeviceToken` on every push. `__DEV__` is not the answer — a local
    Release build (`expo run:ios --configuration Release`) is still signed with
    a development profile. */
export type ApnsEnvironment = "sandbox" | "production";

/**
 * The environment a profile's `aps-environment` entitlement names. The
 * `.mobileprovision` is a CMS blob whose plist rides inside as plain text, so
 * a string search is enough; no profile (App Store builds have none) or no
 * entitlement reads as production.
 */
export function apnsEnvironmentFromProfile(profile: string | null): ApnsEnvironment {
  if (profile === null) return "production";
  const match = /<key>aps-environment<\/key>\s*<string>([^<]*)<\/string>/.exec(profile);
  return match?.[1]?.trim() === "development" ? "sandbox" : "production";
}
