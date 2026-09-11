import type { InfinitusFleet, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/**
 * Session priority mode for the threads this server runs (#616): the pure
 * half. A thread is background unless pinned; a background thread's turn
 * start waits while the fleet its driver runs on reads `low` headroom and
 * runs again when it reads `abundant`. The verdict itself is native's
 * (hysteresis, forecast, the prefs); the fork only reads it.
 */

/** The work-log rows a hold leaves in the thread. Free-form kinds, no
    contract change, no `.failed` suffix so they never read as severe. */
export const HOLD_MARKER_KIND = "infinitus.thread.held";
export const RELEASE_MARKER_KIND = "infinitus.thread.released";

/** Two threads released by one abundant reading start this far apart, so a
    fleet flipping to abundant does not start every held turn at once and
    flip itself back. */
export const RELEASE_SPACING_MS = 2_000;

export type ReleaseReason = "abundant" | "pinned" | "user";

/** The fleet provider a driver's threads spend on; null for a driver whose
    accounts no engine holds (never held). */
export function fleetProviderForDriver(driver: string): string | null {
  switch (driver) {
    case "claudeAgent":
      return "claude";
    case "codex":
      return "codex";
    default:
      return null;
  }
}

export type HeadroomVerdict =
  | { readonly verdict: "hold"; readonly fleet: InfinitusFleet }
  | { readonly verdict: "release"; readonly fleet: InfinitusFleet }
  | { readonly verdict: "unknown" };

const isLow = (fleet: InfinitusFleet): boolean =>
  fleet.headroom?.state === "low" || fleet.headroom?.state === "critical";

/**
 * What the provider's fleets say about spending: `release` when any fleet
 * with an active account reads abundant, `hold` when every one reads low
 * (or critical, which is low until Interrupt exists), else `unknown` — no
 * fleet, no active account, or a fleet that publishes no verdict (mode off,
 * an older build). Two fleets for one provider happen during the cswap to
 * swapd transition (#475); a silent one never holds.
 */
export function headroomVerdict(snapshot: InfinitusSnapshot, provider: string): HeadroomVerdict {
  const fleets = snapshot.fleets.filter(
    (fleet) => fleet.provider === provider && fleet.accounts.some((account) => account.active),
  );
  const abundant = fleets.find((fleet) => fleet.headroom?.state === "abundant");
  if (abundant !== undefined) return { verdict: "release", fleet: abundant };
  const low = fleets[0];
  if (low !== undefined && fleets.every(isLow)) return { verdict: "hold", fleet: low };
  return { verdict: "unknown" };
}

/** The held row's line: the fleet, and the binding window when native names it. */
export function holdMarkerSummary(fleet: InfinitusFleet): string {
  const base = `Held for headroom on ${fleet.provider}`;
  const window = fleet.headroom?.window;
  const pct = fleet.headroom?.pct;
  if (window === undefined || pct === undefined) return base;
  return `${base}, ${window} window ${Math.round(pct)} %`;
}

/** The released row's line. */
export function releaseMarkerSummary(reason: ReleaseReason, provider: string): string {
  switch (reason) {
    case "abundant":
      return `Released: headroom abundant on ${provider}`;
    case "pinned":
      return "Released: pinned";
    case "user":
      return "Released: run now";
  }
}
