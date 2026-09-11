import type { InfinitusFleet, InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/**
 * Session priority mode, interrupt (#743): the pure half. In interrupt mode
 * native publishes `critical` on a fleet where hold mode publishes `low`
 * (same threshold, same hysteresis back to `abundant`); the fork reads only
 * the verdict. `low` holds background starts (the hold layer); `critical`
 * also pauses the background turns already running on the fleet; `abundant`
 * continues them. A thread is background unless pinned.
 */

/** The work-log rows a pause leaves in the thread, mirrors of the hold
    layer's held/released rows so the clients can read them the same way. */
export const PAUSE_MARKER_KIND = "infinitus.thread.paused";
export const RESUME_MARKER_KIND = "infinitus.thread.resumed";

/** The `prefs` catalog key and the value that turns interrupt mode on. Read
    only to know whether running turns are worth watching at all: the
    verdict that pauses one is the fleet's `headroom.state`, never the pref. */
const PRIORITY_MODE_KEY = "priority_mode";
const INTERRUPT_MODE = "interrupt";

/** Why a paused turn continued: the fleet read abundant, the thread was
    pinned, the user said "Resume now", or a real poll carried no verdict
    for the fleet any more (mode turned off, or the account swapped). */
export type ResumeReason = "abundant" | "pinned" | "user" | "off";

export type InterruptVerdict =
  | { readonly verdict: "interrupt"; readonly fleet: InfinitusFleet }
  | { readonly verdict: "resume"; readonly fleet: InfinitusFleet }
  | { readonly verdict: "keep" }
  | { readonly verdict: "unknown" };

const isLow = (fleet: InfinitusFleet): boolean =>
  fleet.headroom?.state === "low" || fleet.headroom?.state === "critical";

/**
 * What the provider's fleets say about turns already running: `resume` when
 * any fleet with an active account reads abundant, `interrupt` when every one
 * reads low or critical and at least one reads critical, `keep` when every
 * one reads low (hold mode: starts wait, running turns finish), else
 * `unknown` — no fleet, no active account, or a fleet without a verdict.
 */
export function interruptVerdict(snapshot: InfinitusSnapshot, provider: string): InterruptVerdict {
  const fleets = snapshot.fleets.filter(
    (fleet) => fleet.provider === provider && fleet.accounts.some((account) => account.active),
  );
  const abundant = fleets.find((fleet) => fleet.headroom?.state === "abundant");
  if (abundant !== undefined) return { verdict: "resume", fleet: abundant };
  if (fleets.length === 0 || !fleets.every(isLow)) return { verdict: "unknown" };
  const critical = fleets.find((fleet) => fleet.headroom?.state === "critical");
  return critical === undefined ? { verdict: "keep" } : { verdict: "interrupt", fleet: critical };
}

/** Whether running turns are worth watching: the app says interrupt mode is
    on, or a fleet already reads `critical` (a state only that mode emits).
    Prefs ride the slow poll; an app without them never arms this. */
export function interruptModeOn(snapshot: InfinitusSnapshot): boolean {
  if (
    snapshot.prefs?.prefs.some(
      (pref) => pref.key === PRIORITY_MODE_KEY && pref.value === INTERRUPT_MODE,
    ) === true
  ) {
    return true;
  }
  return snapshot.fleets.some((fleet) => fleet.headroom?.state === "critical");
}

/** The paused row's line: the fleet, and the binding window when native names it. */
export function pauseMarkerSummary(fleet: InfinitusFleet): string {
  const base = `Paused for headroom on ${fleet.provider}`;
  const window = fleet.headroom?.window;
  const pct = fleet.headroom?.pct;
  if (window === undefined || pct === undefined) return base;
  return `${base}, ${window} window ${Math.round(pct)} %`;
}

/** The resumed row's line. */
export function resumeMarkerSummary(reason: ResumeReason, provider: string): string {
  switch (reason) {
    case "abundant":
      return `Resumed: headroom abundant on ${provider}`;
    case "pinned":
      return "Resumed: pinned";
    case "user":
      return "Resumed: resume now";
    case "off":
      return `Resumed: no headroom verdict on ${provider}`;
  }
}
