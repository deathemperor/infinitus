import { infinitusAccountLabel } from "@t3tools/client-runtime/state/infinitus";
import type {
  InfinitusAccount,
  InfinitusFleet,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import * as Schema from "effect/Schema";

/** A port of native `FleetAlarms` (#86): the phone's own alarms, planned from
    the snapshot it already holds — an exhausted account's limit lifting soon,
    and the account the fleet just swapped to. Pure: snapshots in, alarms out;
    the bridge schedules each as a local notification, re-planned per snapshot. */
export interface FleetAlarm {
  readonly id: string;
  /** ISO instant, or null for "now" (the swap banner). */
  readonly fireAt: string | null;
  readonly title: string;
  readonly body: string;
}

/** The Mac's revive lead (Settings › Notifications, `revive_lead_minutes`)
    when the snapshot carries prefs; ten minutes otherwise. */
export const DEFAULT_LEAD_MS = 10 * 60_000;

const Window = Schema.Struct({
  pct: Schema.Finite,
  resetsAt: Schema.optionalKey(Schema.NullOr(Schema.String)),
  name: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
const Usage = Schema.Struct({
  fiveHour: Schema.optionalKey(Schema.NullOr(Window)),
  sevenDay: Schema.optionalKey(Schema.NullOr(Window)),
  scoped: Schema.optionalKey(Schema.NullOr(Schema.Array(Window))),
});
const decodeUsage = Schema.decodeUnknownOption(Usage);

export function leadMs(snapshot: InfinitusSnapshot): number {
  const pref = snapshot.prefs?.prefs.find((entry) => entry.key === "revive_lead_minutes");
  const minutes = pref?.value;
  return typeof minutes === "number" && Number.isFinite(minutes) && minutes > 0
    ? minutes * 60_000
    : DEFAULT_LEAD_MS;
}

function parseInstant(value: string | null | undefined): number | null {
  if (typeof value !== "string") return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : null;
}

/** The window that governs an exhausted account's return: of every window
    at or over its limit, the one resetting LAST (all of them must lift). The
    spend cap is deliberately not a cause — spent credit leaves the
    subscription windows usable. Null for a live account or one whose blocking
    window carries no reset instant. */
function governingReset(account: InfinitusAccount): { at: number; window: string } | null {
  if (account.usage === undefined) return null;
  const decoded = decodeUsage(account.usage);
  if (decoded._tag !== "Some") return null;
  const usage = decoded.value;
  const dead: Array<{ at: number | null; window: string }> = [];
  if (usage.fiveHour && usage.fiveHour.pct >= 100)
    dead.push({ at: parseInstant(usage.fiveHour.resetsAt), window: "session" });
  if (usage.sevenDay && usage.sevenDay.pct >= 100)
    dead.push({ at: parseInstant(usage.sevenDay.resetsAt), window: "weekly" });
  for (const scoped of usage.scoped ?? []) {
    if (scoped.pct >= 100)
      dead.push({ at: parseInstant(scoped.resetsAt), window: scoped.name ?? "model" });
  }
  if (dead.length === 0) return null;
  let latest = dead[0]!;
  for (const candidate of dead) {
    if ((candidate.at ?? Infinity) > (latest.at ?? Infinity)) latest = candidate;
  }
  return latest.at === null ? null : { at: latest.at, window: latest.window };
}

function clock(ms: number): string {
  return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

/** One alarm per exhausted account (held ones excluded), `lead` before the
    reset that governs its return. A reset already inside the lead window gets
    none: the countdown is on screen, and a past trigger never fires. */
export function resetAlarms(fleet: InfinitusFleet, now: number, lead: number): FleetAlarm[] {
  const alarms: FleetAlarm[] = [];
  for (const account of fleet.accounts) {
    if (account.disabled === true) continue;
    const reset = governingReset(account);
    if (reset === null) continue;
    const fireAt = reset.at - lead;
    if (fireAt <= now) continue;
    alarms.push({
      id: `infinitus-reset-${fleet.key}-${account.number}`,
      fireAt: new Date(fireAt).toISOString(),
      title: `${infinitusAccountLabel(account)} resets in ${Math.round(lead / 60_000)} min`,
      body: `the ${reset.window} limit lifts at ${clock(reset.at)}`,
    });
  }
  return alarms;
}

/** The swap banner: only a change between two looks at the same fleet — the
    first look seeds, and an account the fleet no longer lists says nothing. */
export function swapAlarm(
  previousActive: number | null | undefined,
  fleet: InfinitusFleet,
): FleetAlarm | null {
  const current = fleet.activeNumber;
  if (previousActive === null || previousActive === undefined) return null;
  if (current === null || current === undefined || current === previousActive) return null;
  const account = fleet.accounts.find((candidate) => candidate.number === current);
  if (account === undefined) return null;
  return {
    id: `infinitus-swap-${fleet.key}`,
    fireAt: null,
    title: `swapped to ${infinitusAccountLabel(account)}`,
    body: `account ${current} is live — sessions ride it now`,
  };
}

/** Everything one Mac's snapshot asks the phone to schedule right now. */
export function planAlarms(
  snapshot: InfinitusSnapshot,
  previous: InfinitusSnapshot | null,
  now: number,
): FleetAlarm[] {
  if (!snapshot.available) return [];
  const lead = leadMs(snapshot);
  const alarms: FleetAlarm[] = [];
  for (const fleet of snapshot.fleets) {
    alarms.push(...resetAlarms(fleet, now, lead));
    const before = previous?.fleets.find((candidate) => candidate.key === fleet.key);
    const swap = swapAlarm(before?.activeNumber, fleet);
    if (swap) alarms.push(swap);
  }
  return alarms;
}

/** Which scheduled ids belong to this planner (so it never cancels T3's). */
export function isInfinitusAlarmId(id: string): boolean {
  return id.startsWith("infinitus-");
}
