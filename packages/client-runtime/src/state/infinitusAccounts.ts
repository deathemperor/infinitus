import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import * as DateTime from "effect/DateTime";
import * as Schema from "effect/Schema";

import { infinitusAccountLabel } from "./infinitus.ts";

/**
 * The Accounts page's whole read model, kept pure so the page component only
 * maps rows to markup. Everything here is derived from one `InfinitusSnapshot`
 * plus the environment's `infinitus` capability; nothing reaches for a clock,
 * so the same snapshot always yields the same rows.
 */

/** What a row's buttons can ask the control socket to do. */
export type AccountAction = "switch" | "hold" | "unhold" | "prefer" | "rename";

/** One usage window drawn as a bar. `countdown` is the engine's own
    human string ("2h 14m"), absent on a window that has not started. */
export interface UsageWindowBar {
  readonly name: string;
  readonly pct: number;
  readonly countdown: string | null;
  readonly aheadOfPace: boolean | null;
}

/** One account's row. `next` marks the account auto-switch would pick next,
    `held` an account the engine is skipping until it is unheld. */
export interface AccountRowModel {
  readonly number: number;
  readonly label: string;
  readonly plan: string | null;
  readonly active: boolean;
  readonly next: boolean;
  readonly preferred: boolean;
  readonly held: boolean;
  readonly windows: ReadonlyArray<UsageWindowBar>;
  readonly scoped: ReadonlyArray<UsageWindowBar>;
  readonly freshness: string | null;
  readonly actions: ReadonlyArray<AccountAction>;
}

/** One fleet's section. `key` is what every account command takes as
    `<fleet>`; `caveat` is the engine's own warning line, when it has one. */
export interface FleetSectionModel {
  readonly key: string;
  readonly title: string;
  readonly caveat: string | null;
  readonly rows: ReadonlyArray<AccountRowModel>;
}

/** The fleet-wide run-rate projection. Estimates, never billing truth. */
export interface ForecastModel {
  readonly allDeadAt: string | null;
  readonly drainOrder: ReadonlyArray<string>;
  readonly computedAt: string | null;
}

/** What the page shows before it can show rows. */
export type AccountsPageState = "unsupported" | "loading" | "unavailable" | "empty" | "ready";

/**
 * The native usage payload, which the contract leaves opaque. Decoded here
 * defensively: every key may be missing, and a payload shaped differently than
 * this reads as "no windows" rather than throwing at render time.
 */
const UsageWindowPayload = Schema.Struct({
  name: Schema.optionalKey(Schema.String),
  pct: Schema.Finite,
  countdown: Schema.optionalKey(Schema.String),
  aheadOfPace: Schema.optionalKey(Schema.Boolean),
});

const UsagePayload = Schema.Struct({
  fiveHour: Schema.optionalKey(UsageWindowPayload),
  sevenDay: Schema.optionalKey(UsageWindowPayload),
  scoped: Schema.optionalKey(Schema.Array(UsageWindowPayload)),
});

const decodeUsage = Schema.decodeUnknownOption(UsagePayload);

/** Usage statuses that still carry a reading worth dating; every other status
    the engines report ("error", "disabled", "relogin_required", "token_expired",
    "no_credentials", "api_key") means there is no usage to show. */
const READABLE_USAGE_STATUSES = new Set(["ok", "stale", "warning"]);

function bar(window: typeof UsageWindowPayload.Type, fallbackName: string): UsageWindowBar {
  return {
    name: window.name ?? fallbackName,
    pct: Math.min(100, Math.max(0, Math.round(window.pct))),
    countdown: window.countdown ?? null,
    aheadOfPace: window.aheadOfPace ?? null,
  };
}

/** The rolling windows in reading order and the per-model ones beside them.
    A scoped window with no name has nothing to label its bar, so it is dropped. */
function usageBars(account: InfinitusAccount): {
  windows: ReadonlyArray<UsageWindowBar>;
  scoped: ReadonlyArray<UsageWindowBar>;
} {
  if (account.usage === undefined) return { windows: [], scoped: [] };
  const decoded = decodeUsage(account.usage);
  if (decoded._tag !== "Some") return { windows: [], scoped: [] };
  const usage = decoded.value;
  const windows: UsageWindowBar[] = [];
  if (usage.fiveHour) windows.push(bar(usage.fiveHour, "5h"));
  if (usage.sevenDay) windows.push(bar(usage.sevenDay, "7d"));
  const scoped = (usage.scoped ?? [])
    .filter((window) => window.name !== undefined && window.name !== "")
    .map((window) => bar(window, ""));
  return { windows, scoped };
}

/** How old the reading is, in the row's own words. Null when the engine
    reported a usable status but no age, which is the only unknown case. */
function freshnessLabel(account: InfinitusAccount): string | null {
  if (!READABLE_USAGE_STATUSES.has(account.usageStatus)) return "usage unavailable";
  const seconds = account.usageAgeSeconds;
  if (seconds === undefined || !Number.isFinite(seconds)) return null;
  if (seconds < 60) return "updated just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `updated ${minutes} min ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `updated ${hours} hr ago`;
  const days = Math.floor(hours / 24);
  return `updated ${days} ${days === 1 ? "day" : "days"} ago`;
}

/**
 * What this row may ask for, read off the fleet's capabilities alone — never
 * off the engine's identity. Switching to the account already in use is not
 * offered, hold and unhold are the two halves of one capability, and the
 * pick-first star is hidden on an engine whose accounts carry no `preferred`
 * knob (the control socket refuses `prefer` there).
 */
function rowActions(
  fleet: InfinitusFleet,
  account: InfinitusAccount,
): ReadonlyArray<AccountAction> {
  const capabilities = new Set(fleet.capabilities);
  const actions: AccountAction[] = [];
  const active = account.active || fleet.activeNumber === account.number;
  if (capabilities.has("switch") && !active) actions.push("switch");
  if (capabilities.has("hold")) actions.push(account.disabled === true ? "unhold" : "hold");
  if (capabilities.has("prefer") && account.preferred !== undefined) actions.push("prefer");
  if (capabilities.has("rename")) actions.push("rename");
  return actions;
}

function buildRow(fleet: InfinitusFleet, account: InfinitusAccount): AccountRowModel {
  const { windows, scoped } = usageBars(account);
  return {
    number: account.number,
    label: infinitusAccountLabel(account),
    plan: account.plan ?? null,
    active: account.active || fleet.activeNumber === account.number,
    next: fleet.nextCandidate === account.number,
    preferred: account.preferred === true,
    held: account.disabled === true,
    windows,
    scoped,
    freshness: freshnessLabel(account),
    actions: rowActions(fleet, account),
  };
}

/** Which of the page's five shapes to draw. The capability answers first: an
    environment without Infinitus never reaches a snapshot at all. */
export function accountsPageState(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
}): AccountsPageState {
  if (input.capability !== true) return "unsupported";
  if (input.snapshot === null) return "loading";
  if (!input.snapshot.available) return "unavailable";
  if (input.snapshot.fleets.length === 0) return "empty";
  return "ready";
}

/** One fleet's section, rows in account-number order. The title names the
    provider, and the engine behind it only when the two differ. */
export function buildFleetSection(fleet: InfinitusFleet): FleetSectionModel {
  return {
    key: fleet.key,
    title:
      fleet.provider === fleet.engineID ? fleet.provider : `${fleet.provider} (${fleet.engineID})`,
    caveat: fleet.caveat ?? null,
    rows: [...fleet.accounts]
      .sort((left, right) => left.number - right.number)
      .map((account) => buildRow(fleet, account)),
  };
}

/** The native forecast dates its instants as epoch seconds
    (`UsageForecast.computedAt: Double`, from `Date().timeIntervalSince1970`),
    so they become ISO strings here. */
function isoFromEpochSeconds(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const instant = DateTime.make(value * 1000);
  return instant._tag === "Some" ? DateTime.formatIso(instant.value) : null;
}

/** The label a drain-order number stands for, looked up across every fleet.
    Numbers are per-fleet, so the first match wins; a number no fleet knows
    stays a bare `#n` rather than disappearing from the order. */
function drainLabel(snapshot: InfinitusSnapshot, number: number): string {
  for (const fleet of snapshot.fleets) {
    const account = fleet.accounts.find((candidate) => candidate.number === number);
    if (account) return infinitusAccountLabel(account);
  }
  return `#${number}`;
}

/** The fleet-wide projection, or null when the app has nothing to project.
    The contract pins only the top-level keys, so each one is narrowed here and
    a field the app omitted simply reads as empty. */
export function buildForecast(snapshot: InfinitusSnapshot): ForecastModel | null {
  const forecast = snapshot.forecast?.forecast;
  if (forecast === undefined || forecast === null) return null;
  const drainOrder = Array.isArray(forecast.drainOrder)
    ? forecast.drainOrder
        .filter((entry): entry is number => typeof entry === "number")
        .map((entry) => drainLabel(snapshot, entry))
    : [];
  return {
    allDeadAt: isoFromEpochSeconds(forecast.allDeadAt),
    drainOrder,
    computedAt: isoFromEpochSeconds(forecast.computedAt),
  };
}

/**
 * The control-socket call a row's button makes. `prefer` is a toggle and takes
 * the side it is switching to, which is what the socket's
 * `prefer <fleet> <n> on|off` expects; the other four take the account alone.
 */
export function accountCommandArgs(
  fleetKey: string,
  row: AccountRowModel,
  action: AccountAction,
  alias?: string,
): { command: string; args: ReadonlyArray<string> } {
  const target = [fleetKey, String(row.number)];
  if (action === "rename") {
    if (alias === undefined) throw new Error("rename needs an alias");
    return { command: "rename", args: [...target, alias] };
  }
  if (action === "prefer") {
    return { command: "prefer", args: [...target, row.preferred ? "off" : "on"] };
  }
  return { command: action, args: target };
}
