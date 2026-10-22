export type MobileStageLabel = "Alpha" | "Dev" | "Nightly";

// The fork's line is versioned alpha (0.5.0-alpha.N), so its builds keep
// "Alpha" where upstream's stable stage moved to "Beta".
export function resolveMobileStageLabel(appVariant: unknown): MobileStageLabel {
  if (appVariant === "development") return "Dev";
  if (appVariant === "preview") return "Nightly";
  return "Alpha";
}

/**
 * Which app icon the brand lockup draws. `infinitus` is the fork's own build
 * and must never fall through to `prod`, which is upstream's T3 mark — that
 * fallthrough put T3's logo beside the Infinitus wordmark on loading screens.
 */
export type MobileBrandMarkVariant = "infinitus" | "development" | "preview" | "prod";

export function resolveMobileBrandMarkVariant(appVariant: unknown): MobileBrandMarkVariant {
  if (appVariant === "infinitus") return "infinitus";
  if (appVariant === "development") return "development";
  if (appVariant === "preview") return "preview";
  return "prod";
}
