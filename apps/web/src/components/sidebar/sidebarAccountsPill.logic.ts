import {
  accountsPageState,
  buildFleetSection,
  type UsageWindowBar,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import {
  infinitusAccountLabel,
  infinitusActiveAccount,
} from "@t3tools/client-runtime/state/infinitus";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";

/**
 * What the sidebar's Infinitus pill says, derived from one snapshot alone so the
 * component only draws it. The page's own `accountsPageState` decides which
 * shape applies, which keeps the pill and the page from disagreeing about when
 * Infinitus is there.
 */
export interface SidebarAccountsPillView {
  readonly text: string;
  readonly tooltip: string;
  /** True on the offline shape: muted, not a link to the page. */
  readonly offline: boolean;
}

/** The window closest to running out, which is simply the fuller one. */
function tightestWindow(windows: ReadonlyArray<UsageWindowBar>): UsageWindowBar | null {
  return windows.reduce<UsageWindowBar | null>(
    (tightest, window) => (tightest === null || window.pct > tightest.pct ? window : tightest),
    null,
  );
}

/**
 * The pill's line, or null when there is nothing worth a footer row: no
 * Infinitus on this environment, a snapshot still loading, no fleets at all, or
 * fleets whose engines report no account in use.
 */
export function sidebarAccountsPillView(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
}): SidebarAccountsPillView | null {
  const state = accountsPageState(input);
  if (state === "unavailable") {
    const reason = input.snapshot?.unavailableReason;
    return {
      text: "Infinitus offline",
      tooltip: reason !== undefined && reason !== "" ? reason : "Infinitus offline",
      offline: true,
    };
  }
  if (state !== "ready" || input.snapshot === null) return null;

  for (const fleet of input.snapshot.fleets) {
    const active = infinitusActiveAccount(fleet);
    if (active === null) continue;
    const label = infinitusAccountLabel(active);
    const row = buildFleetSection(fleet).rows.find(
      (candidate) => candidate.number === active.number,
    );
    const window = row === undefined ? null : tightestWindow(row.windows);
    if (window === null) return { text: label, tooltip: label, offline: false };
    const usage = `${window.name} ${window.pct}%`;
    return { text: `${label} · ${usage}`, tooltip: `${label} · ${usage} used`, offline: false };
  }
  return null;
}
