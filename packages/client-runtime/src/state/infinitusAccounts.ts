import type { ExecutionEnvironmentCapabilities } from "@t3tools/contracts";
import type {
  InfinitusAccount,
  InfinitusAwsLogin,
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
  /** The engine's ISO instant the window rolls at; null when it sends none. */
  readonly resetsAt: string | null;
}

/** One account's row. `next` marks the account auto-switch would pick next,
    `held` an account the engine is skipping until it is unheld. */
export interface AccountRowModel {
  readonly number: number;
  readonly label: string;
  /** The account's email — what a re-login names to the app. */
  readonly email: string;
  readonly plan: string | null;
  readonly active: boolean;
  readonly next: boolean;
  readonly preferred: boolean;
  readonly held: boolean;
  readonly windows: ReadonlyArray<UsageWindowBar>;
  readonly scoped: ReadonlyArray<UsageWindowBar>;
  readonly freshness: string | null;
  readonly actions: ReadonlyArray<AccountAction>;
  /** The engine says the stored sign-in expired and the fleet can run a new
      one: the row offers "Sign in again" (native's "Sign-In Needed" chip). */
  readonly reloginNeeded: boolean;
}

/** One fleet's section. `key` is what every account command takes as
    `<fleet>`; `caveat` is the engine's own warning line, when it has one. */
export interface FleetSectionModel {
  readonly key: string;
  readonly title: string;
  readonly caveat: string | null;
  readonly rows: ReadonlyArray<AccountRowModel>;
  /** The fleet runs an in-app sign-in (`add <fleet>`), so the section offers
      "Add account". Read off the capabilities, never the engine's name. */
  readonly canAdd: boolean;
}

/** One window of one account's projection: where it stands, the measured
    pace, and when it fills at that pace (`null` when the reset lands first or
    the pace is unknown). Instants are ISO strings. */
export interface ForecastWindowModel {
  readonly name: string;
  readonly pct: number;
  readonly ratePctPerHour: number | null;
  readonly resetsAt: string | null;
  readonly hitsAt: string | null;
}

/** One account's projection at its own measured pace (the Utilization page's
    forecast section, #747). `bindsAt`/`bindsWindow` are the earliest `hitsAt`
    across its windows, what native's `AccountLine.bindsAt` computes. */
export interface ForecastLineModel {
  readonly number: number;
  readonly label: string;
  readonly active: boolean;
  readonly disabled: boolean;
  readonly windows: ReadonlyArray<ForecastWindowModel>;
  readonly bindsAt: string | null;
  readonly bindsWindow: string | null;
}

/** The fleet-wide run-rate projection. Estimates, never billing truth. */
export interface ForecastModel {
  readonly allDeadAt: string | null;
  readonly drainOrder: ReadonlyArray<string>;
  readonly computedAt: string | null;
  /** What the numbers rest on, the app's own words; null when it sent none. */
  readonly basis: string | null;
  /** Whether the app projected an active account at all. */
  readonly hasActive: boolean;
  /** Every account's line, in the app's order; `[]` on a build that does not
      send them or a shape this reader does not know. */
  readonly accounts: ReadonlyArray<ForecastLineModel>;
}

/** What every Infinitus page shows before it can show its own body. */
export type InfinitusPageState = "unsupported" | "loading" | "unavailable" | "ready";

/** What the Accounts page shows before it can show rows. */
export type AccountsPageState = InfinitusPageState | "empty";

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
  resetsAt: Schema.optionalKey(Schema.String),
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
    resetsAt: window.resetsAt ?? null,
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

/** The capability the native `add <fleet>` verb acts on: the in-app OAuth
    sign-in (swapd declares every capability, the proxy this one). A fleet with
    only `addToken` pastes a token in the Mac app and is not offered here. */
const ADD_CAPABILITY = "addOAuth";

/** The usage status the engines report for a stored sign-in that expired. */
const RELOGIN_USAGE_STATUS = "relogin_required";

function fleetCanAdd(fleet: InfinitusFleet): boolean {
  return fleet.capabilities.includes(ADD_CAPABILITY);
}

function buildRow(fleet: InfinitusFleet, account: InfinitusAccount): AccountRowModel {
  const { windows, scoped } = usageBars(account);
  return {
    number: account.number,
    label: infinitusAccountLabel(account),
    email: account.email,
    plan: account.plan ?? null,
    active: account.active || fleet.activeNumber === account.number,
    next: fleet.nextCandidate === account.number,
    preferred: account.preferred === true,
    held: account.disabled === true,
    windows,
    scoped,
    freshness: freshnessLabel(account),
    actions: rowActions(fleet, account),
    reloginNeeded: fleetCanAdd(fleet) && account.usageStatus === RELOGIN_USAGE_STATUS,
  };
}

/** The gate every Infinitus page passes before drawing its own body. Only a
    server that answered `false` lacks the adapter; `undefined` is a server
    whose config has not arrived yet, so the page waits for it the way it waits
    for the snapshot (#693). */
export function infinitusPageState(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
}): InfinitusPageState {
  if (input.capability === false) return "unsupported";
  if (input.capability === undefined || input.snapshot === null) return "loading";
  if (!input.snapshot.available) return "unavailable";
  return "ready";
}

/** One server's answer. No config yet is "not known yet"; a config that
    arrived without the field is a server without the adapter at all (an
    upstream one), which must show the missing-adapter copy, never a skeleton
    for good. */
export function infinitusCapabilityOf(
  capabilities: Pick<ExecutionEnvironmentCapabilities, "infinitus"> | undefined,
): boolean | undefined {
  if (capabilities === undefined) return undefined;
  return capabilities.infinitus ?? false;
}

/** One capability for the Accounts page, which spans every environment: any
    server with the adapter counts, a page that heard only `false` lacks it,
    and one nobody has answered yet stays `undefined`. */
export function infinitusCapabilityAcross(
  capabilities: Iterable<boolean | undefined>,
): boolean | undefined {
  let answer: boolean | undefined;
  for (const capability of capabilities) {
    if (capability === true) return true;
    if (capability === false) answer = false;
  }
  return answer;
}

/** Which of the page's five shapes to draw: the shared gate, then `empty` for a
    host that answered with no fleets. */
export function accountsPageState(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
}): AccountsPageState {
  const gate = infinitusPageState(input);
  if (gate !== "ready" || input.snapshot === null) return gate;
  return input.snapshot.fleets.length === 0 ? "empty" : "ready";
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
    canAdd: fleetCanAdd(fleet),
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

/** The forecast's account lines, which the contract leaves opaque. Every key
    the app may omit is optional here; a line missing its identity is dropped
    on its own, so one odd line never blanks the section. */
const ForecastWindowPayload = Schema.Struct({
  name: Schema.String,
  pct: Schema.Finite,
  ratePctPerHour: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
  resetsAt: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
  hitsAt: Schema.optionalKey(Schema.NullOr(Schema.Finite)),
});

const ForecastLinePayload = Schema.Struct({
  number: Schema.Finite,
  email: Schema.String,
  alias: Schema.optionalKey(Schema.NullOr(Schema.String)),
  active: Schema.optionalKey(Schema.Boolean),
  disabled: Schema.optionalKey(Schema.Boolean),
  windows: Schema.optionalKey(Schema.Array(Schema.Unknown)),
});

const decodeForecastLine = Schema.decodeUnknownOption(ForecastLinePayload);
const decodeForecastWindow = Schema.decodeUnknownOption(ForecastWindowPayload);

function forecastWindow(payload: unknown): ForecastWindowModel | null {
  const window = decodeForecastWindow(payload);
  if (window._tag === "None") return null;
  return {
    name: window.value.name,
    pct: Math.min(100, Math.max(0, Math.round(window.value.pct))),
    ratePctPerHour: window.value.ratePctPerHour ?? null,
    resetsAt: isoFromEpochSeconds(window.value.resetsAt),
    hitsAt: isoFromEpochSeconds(window.value.hitsAt),
  };
}

function forecastLine(payload: unknown): ForecastLineModel | null {
  const line = decodeForecastLine(payload);
  if (line._tag === "None") return null;
  const windows = (line.value.windows ?? [])
    .map(forecastWindow)
    .filter((window): window is ForecastWindowModel => window !== null);
  const binding = windows
    .filter((window) => window.hitsAt !== null)
    .sort((left, right) => (left.hitsAt ?? "").localeCompare(right.hitsAt ?? ""))[0];
  const alias = line.value.alias ?? "";
  return {
    number: line.value.number,
    label: alias !== "" ? alias : line.value.email,
    active: line.value.active ?? false,
    disabled: line.value.disabled ?? false,
    windows,
    bindsAt: binding?.hitsAt ?? null,
    bindsWindow: binding?.name ?? null,
  };
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
  const accounts = Array.isArray(forecast.accounts)
    ? forecast.accounts.map(forecastLine).filter((line): line is ForecastLineModel => line !== null)
    : [];
  return {
    allDeadAt: isoFromEpochSeconds(forecast.allDeadAt),
    drainOrder,
    computedAt: isoFromEpochSeconds(forecast.computedAt),
    basis: typeof forecast.basis === "string" ? forecast.basis : null,
    hasActive: forecast.active !== undefined && forecast.active !== null,
    accounts,
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

/*
 * Add account / re-login: the native `add <fleet>` verb opens the app's own
 * sign-in (a system sheet or a private window on the Mac — never the fork's
 * browser); `wait-add` blocks until it ends. Re-login is the same flow: the
 * verb takes no account, so the page only names who to sign in as.
 */

/** Whether the running build has the verb at all; an older app answers
    "unknown command", so the buttons stay hidden without it. */
export function snapshotOffersAdd(snapshot: InfinitusSnapshot): boolean {
  return snapshot.commands.some((command) => command.name === "add");
}

/** The app's own word on whether a sign-in is running — started from here,
    from another client or from the Mac app itself. `add` is refused while
    one runs, so every add/re-login button waits on it. */
export function snapshotSignInRunning(snapshot: InfinitusSnapshot): boolean {
  return snapshot.status?.signInRunning === true;
}

/** `add <fleet>`: answers `{started:true}` once the sign-in is on screen. */
export function addAccountCommandArgs(fleetKey: string): {
  command: string;
  args: ReadonlyArray<string>;
  options: Record<string, string>;
} {
  return { command: "add", args: [fleetKey], options: {} };
}

/** `wait-add --timeout <s>`: one short poll. The server's socket client gives
    a command ten seconds, so the page polls in steps rather than asking the
    app for the whole five-minute wait. */
export function waitAddCommandArgs(timeoutSeconds: number): {
  command: string;
  args: ReadonlyArray<string>;
  options: Record<string, string>;
} {
  return { command: "wait-add", args: [], options: { timeout: String(timeoutSeconds) } };
}

/** The refusal text native answers a `wait-add` whose window closed while the
    sign-in still runs ("timed out after 5s"); the page keeps polling on it.
    Any other refusal is the sign-in's own failure. */
export const WAIT_ADD_STILL_RUNNING = /^timed out/;

const WaitAddPayload = Schema.Struct({
  done: Schema.Boolean,
  error: Schema.optionalKey(Schema.NullOr(Schema.String)),
});

const decodeWaitAdd = Schema.decodeUnknownOption(WaitAddPayload);

/** What a `wait-add` reply's `result` says, or null when it is not one. */
export function waitAddOutcome(result: unknown): { done: boolean; error: string | null } | null {
  const decoded = decodeWaitAdd(result);
  if (decoded._tag !== "Some") return null;
  return { done: decoded.value.done, error: decoded.value.error ?? null };
}

/*
 * Sign-ins: the AWS profiles and gcloud accounts whose credentials lapsed
 * under a session (`aws-logins`, native #572 task 7), grouped per tool and
 * profile so one row carries every session waiting on it.
 */

/** Which CLI a sign-in belongs to. */
export type SignInTool = "aws" | "gcloud";

/** Where a login stands, folded from the native phases: `waiting` covers
    both `waitingForBrowser` and `waitingForCode`, and any phase a newer
    build adds. */
export type SignInPhase = "idle" | "starting" | "waiting" | "done" | "failed";

/** One lapsed profile. `sessions` are the labels of every session waiting on
    it; `pid` is the most recently lapsed one, which the start command scopes
    to. `deviceCode` says the flag-less flow finishes by itself once the code
    is approved on any device; other flows need the Mac's own browser. `url`,
    `userCode` and `message` are what the running login printed. */
export interface SignInRowModel {
  readonly key: string;
  readonly tool: SignInTool;
  readonly toolLabel: string;
  readonly profile: string;
  readonly failedAt: string | null;
  readonly sessions: ReadonlyArray<string>;
  readonly pid: number | null;
  readonly deviceCode: boolean;
  readonly phase: SignInPhase;
  readonly url: string | null;
  readonly userCode: string | null;
  readonly message: string | null;
}

function signInPhase(state: InfinitusAwsLogin["state"]): SignInPhase {
  const phase = state?.phase;
  if (phase === undefined || phase === null) return "idle";
  if (phase === "starting" || phase === "done" || phase === "failed") return phase;
  return "waiting";
}

/** The session a lapsed item names, by the app's own label first and the
    session list's name second; a session neither knows is its pid. */
function waitingSessionLabel(snapshot: InfinitusSnapshot, item: InfinitusAwsLogin): string {
  if (typeof item.sessionLabel === "string" && item.sessionLabel !== "") return item.sessionLabel;
  const session =
    item.pid === undefined || item.pid === null
      ? undefined
      : snapshot.sessions.find((candidate) => candidate.pid === item.pid);
  if (session?.name) return session.name;
  return item.pid === undefined || item.pid === null ? "a session" : `pid ${item.pid}`;
}

function failedAtMs(item: InfinitusAwsLogin): number {
  if (typeof item.failedAt !== "string") return Number.NEGATIVE_INFINITY;
  const ms = Date.parse(item.failedAt);
  return Number.isNaN(ms) ? Number.NEGATIVE_INFINITY : ms;
}

/**
 * The sign-in rows a snapshot asks for, one per tool and profile, in the order
 * the app listed them. Empty when the build has no `aws-logins` or nothing
 * lapsed. Finished logins stay (as `done`) until the need clears from the
 * list, so the page can say the sign-in went through.
 */
export function buildSignInRows(snapshot: InfinitusSnapshot): ReadonlyArray<SignInRowModel> {
  if (!snapshot.available || snapshot.awsLogins === undefined) return [];
  const groups = new Map<string, { latest: InfinitusAwsLogin; items: InfinitusAwsLogin[] }>();
  for (const item of snapshot.awsLogins) {
    const tool: SignInTool = item.provider === "gcloud" ? "gcloud" : "aws";
    const key = `${tool}:${item.profile}`;
    const group = groups.get(key);
    if (group === undefined) groups.set(key, { latest: item, items: [item] });
    else {
      group.items.push(item);
      if (failedAtMs(item) > failedAtMs(group.latest)) group.latest = item;
    }
  }
  return [...groups.entries()].map(([key, { latest, items }]) => {
    const tool: SignInTool = latest.provider === "gcloud" ? "gcloud" : "aws";
    const state = items.find((item) => item.state !== undefined && item.state !== null)?.state;
    return {
      key,
      tool,
      toolLabel: tool === "gcloud" ? "gcloud" : "AWS",
      profile: latest.profile,
      failedAt: typeof latest.failedAt === "string" ? latest.failedAt : null,
      sessions: [...new Set(items.map((item) => waitingSessionLabel(snapshot, item)))],
      pid: latest.pid ?? null,
      deviceCode: latest.flow === "deviceCode",
      phase: signInPhase(state),
      url: state?.url ?? null,
      userCode: state?.userCode ?? null,
      message: state?.message ?? null,
    };
  });
}

/**
 * The control-socket call that starts a row's sign-in. A device-code profile
 * runs its natural flow (`aws-login <profile>`): the app prints a URL and a
 * code and finishes by itself once they are approved anywhere. Every other
 * flow takes `--local`, so the Mac opens its own browser — the relay and
 * `--remote` flows finish over stdin, which the fork's RPC never carries.
 */
export function signInCommandArgs(row: SignInRowModel): {
  command: string;
  args: ReadonlyArray<string>;
  options: Record<string, string>;
} {
  const options: Record<string, string> = {};
  if (!row.deviceCode) options.local = "true";
  if (row.pid !== null) options.pid = String(row.pid);
  return {
    command: row.tool === "gcloud" ? "gcloud-login" : "aws-login",
    args: [row.profile],
    options,
  };
}
