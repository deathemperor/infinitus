import type { InfinitusFleet } from "@t3tools/contracts/infinitus";
import * as DateTime from "effect/DateTime";

import {
  buildFleetSection,
  type AccountRowModel,
  type UsageWindowBar,
} from "./infinitusAccounts.ts";

/**
 * The all-accounts-exhausted band (#659): the pop-out's reviver band, kept
 * pure so web and mobile draw the same verdict from one fleet. A port of the
 * native `AccountVitals.isDead` / `RecoveryMath.revival` rules: an account is
 * exhausted when any usage window (5h, 7d or per-model) is at its limit and
 * has not rolled yet; its revival is the LAST reset among those windows (it
 * is usable only once all of them roll); the fleet's next revival is the
 * EARLIEST account revival. Display-only — the engine's own switching policy
 * decides what happens next.
 */

/** Nothing legitimate resets later than a weekly window; a reset further out
    than this is a bad string, not a reviver (native #226). */
const PLAUSIBLE_HORIZON_MS = 8 * 24 * 60 * 60 * 1000;

export interface ExhaustedBandModel {
  /** The earliest instant any account comes back, ISO; null when every
      exhausted window carries no readable reset. */
  readonly revivalAt: string | null;
  /** The label of the account that revives first, when known. */
  readonly revivesFirst: string | null;
}

function iso(ms: number): string {
  return DateTime.formatIso(DateTime.makeUnsafe(ms));
}

function resetMs(window: UsageWindowBar): number | null {
  if (window.resetsAt === null) return null;
  const ms = Date.parse(window.resetsAt);
  return Number.isNaN(ms) ? null : ms;
}

/** A window at its limit whose reset, when it has one, is still ahead: a
    stored reading past its reset belongs to a window that no longer exists. */
function isMaxed(window: UsageWindowBar, nowMs: number): boolean {
  if (window.pct < 100) return false;
  const reset = resetMs(window);
  return reset === null || reset > nowMs;
}

/** When the account is back for good: its last maxed window's reset. Null
    when nothing is maxed. `{ at: null }` when a maxed window has no readable
    reset (unrankable, never "resets now") or the reset is implausibly far. */
function revival(row: AccountRowModel, nowMs: number): { at: number | null } | null {
  const maxed = [...row.windows, ...row.scoped].filter((window) => isMaxed(window, nowMs));
  if (maxed.length === 0) return null;
  let last: number | null = null;
  for (const window of maxed) {
    const reset = resetMs(window);
    if (reset === null) return { at: null };
    if (last === null || reset > last) last = reset;
  }
  return { at: last !== null && last <= nowMs + PLAUSIBLE_HORIZON_MS ? last : null };
}

/**
 * The band for one fleet, or null when it has nothing to say: no accounts
 * to wait on, or at least one unheld account that is not at a limit. A held
 * account is skipped (the engine is not using it), and an account with no
 * usage reading is not provably exhausted, so it keeps the band away.
 */
export function exhaustedBand(fleet: InfinitusFleet, nowMs: number): ExhaustedBandModel | null {
  const rows = buildFleetSection(fleet).rows.filter((row) => !row.held);
  if (rows.length === 0) return null;
  let earliest: { at: number; label: string } | null = null;
  for (const row of rows) {
    const revives = revival(row, nowMs);
    if (revives === null) return null;
    if (revives.at !== null && (earliest === null || revives.at < earliest.at)) {
      earliest = { at: revives.at, label: row.label };
    }
  }
  if (earliest !== null) {
    return { revivalAt: iso(earliest.at), revivesFirst: earliest.label };
  }
  // The engine's own reviver, when no account reset could be ranked.
  const engine = fleet.nextRecovery;
  if (engine !== undefined && !Number.isNaN(Date.parse(engine.at))) {
    const label = rows.find((row) => row.number === engine.number)?.label ?? null;
    return { revivalAt: iso(Date.parse(engine.at)), revivesFirst: label };
  }
  return { revivalAt: null, revivesFirst: null };
}
