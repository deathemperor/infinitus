import type { MenuAction } from "@react-native-menu/menu";
import {
  type AccountAction,
  type AccountRowModel,
  type AccountsPageState,
  accountsPageState,
  buildFleetSection,
  buildForecast,
  type FleetSectionModel,
  type ForecastModel,
} from "@t3tools/client-runtime/state/infinitusAccounts";
import {
  exhaustedBand,
  type ExhaustedBandModel,
} from "@t3tools/client-runtime/state/infinitusExhausted";
import {
  infinitusAccountLabel,
  infinitusActiveAccount,
} from "@t3tools/client-runtime/state/infinitus";
import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";

/** One paired Mac that runs Infinitus: an environment advertising the
    `infinitus` capability. `connected` is the T3 connection, not the Mac's
    Infinitus app — a connected Mac can still answer `available: false`. */
export interface InfinitusMac {
  readonly environmentId: EnvironmentId;
  readonly label: string;
  readonly connected: boolean;
}

/** The Macs the Accounts screen lists, in catalog order. Environments without
    the capability are plain T3 servers and never appear. */
export function infinitusMacs(
  configs: ReadonlyMap<
    EnvironmentId,
    { readonly environment: { readonly capabilities: { readonly infinitus?: boolean } } }
  >,
  presentations: ReadonlyMap<
    EnvironmentId,
    {
      readonly entry: { readonly target: { readonly label: string } };
      readonly connection: { readonly phase: string };
    }
  >,
): ReadonlyArray<InfinitusMac> {
  const macs: InfinitusMac[] = [];
  for (const [environmentId, presentation] of presentations) {
    if (configs.get(environmentId)?.environment.capabilities.infinitus !== true) continue;
    macs.push({
      environmentId,
      label: presentation.entry.target.label,
      connected: presentation.connection.phase === "connected",
    });
  }
  return macs;
}

/** What one Mac's card draws: the shared page state plus its sections and
    forecast, and the app's own words for why it is unavailable. */
export interface MacAccountsModel {
  readonly state: AccountsPageState;
  readonly unavailableReason: string | null;
  readonly sections: ReadonlyArray<FleetSectionModel>;
  /** The all-exhausted band per fleet key (#706), only for fleets whose
      every unheld account is at a limit — web's verdict, from one model. */
  readonly bands: ReadonlyMap<string, ExhaustedBandModel>;
  readonly forecast: ForecastModel | null;
}

export function macAccountsModel(
  snapshot: InfinitusSnapshot | null,
  nowMs: number,
): MacAccountsModel {
  const state = accountsPageState({ capability: true, snapshot });
  if (state !== "ready" || snapshot === null) {
    return {
      state,
      unavailableReason: snapshot?.unavailableReason ?? null,
      sections: [],
      bands: new Map(),
      forecast: null,
    };
  }
  const bands = new Map<string, ExhaustedBandModel>();
  for (const fleet of snapshot.fleets) {
    const band = exhaustedBand(fleet, nowMs);
    if (band !== null) bands.set(fleet.key, band);
  }
  return {
    state,
    unavailableReason: null,
    sections: snapshot.fleets.map(buildFleetSection),
    bands,
    forecast: buildForecast(snapshot),
  };
}

/** The band's one line: the revival as a clock time, "tomorrow at …" or a
    date when further out, and who comes back first when known. The phone has
    no timestamp-format setting, so the device locale formats it. */
export function exhaustedCopy(band: ExhaustedBandModel, nowMs: number): string {
  const when = band.revivalAt === null ? "" : upcoming(band.revivalAt, nowMs);
  if (when === "") return "All accounts exhausted";
  const who = band.revivesFirst === null ? "" : ` (${band.revivesFirst})`;
  return `All accounts exhausted · next revival ${when}${who}`;
}

function upcoming(iso: string, nowMs: number): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const time = date.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const now = new Date(nowMs);
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const startOfDay = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
  const days = Math.round((startOfDay - startOfToday) / 86_400_000);
  if (days <= 0) return time;
  if (days === 1) return `tomorrow at ${time}`;
  return `${date.toLocaleDateString([], { month: "short", day: "numeric" })} ${time}`;
}

/** The row's context menu, one entry per action the shared model allows —
    nothing is re-derived from capabilities here. Ids are the actions. Rename
    needs a text prompt, which only iOS's Alert offers (`canPrompt`). */
export function rowMenuActions(
  row: AccountRowModel,
  options: { readonly canPrompt: boolean },
): ReadonlyArray<MenuAction> {
  return row.actions
    .filter((action) => action !== "rename" || options.canPrompt)
    .map((action) => ({
      id: action,
      title: actionTitle(action, row),
      image: ACTION_SYMBOL[action],
    }));
}

const ACTION_SYMBOL: Record<AccountAction, string> = {
  switch: "arrow.triangle.2.circlepath",
  hold: "pause.circle",
  unhold: "play.circle",
  prefer: "star",
  rename: "pencil",
};

function actionTitle(action: AccountAction, row: AccountRowModel): string {
  switch (action) {
    case "switch":
      return "Switch to this account";
    case "hold":
      return "Hold";
    case "unhold":
      return "Release hold";
    case "prefer":
      return row.preferred ? "Unstar" : "Star (pick first)";
    case "rename":
      return "Rename…";
  }
}

/** The confirmation a switch shows before it runs: the Mac's live sessions
    move to the new account, which is why it is not a silent tap. */
export function switchConfirmation(
  row: AccountRowModel,
  fleetTitle: string,
): { readonly title: string; readonly message: string } {
  return {
    title: `Switch ${fleetTitle} to ${row.label}?`,
    message: "Every live session on the Mac continues on this account.",
  };
}

/** Pills after the label, in a fixed order so rows stay comparable. */
export function rowBadges(
  row: AccountRowModel,
): ReadonlyArray<"active" | "next" | "held" | "starred"> {
  const badges: Array<"active" | "next" | "held" | "starred"> = [];
  if (row.active) badges.push("active");
  if (row.next) badges.push("next");
  if (row.held) badges.push("held");
  if (row.preferred) badges.push("starred");
  return badges;
}

/** How loud a usage bar reads: full bars are the ones about to rate-limit. */
export function windowTone(pct: number): "calm" | "warm" | "hot" {
  if (pct >= 90) return "hot";
  if (pct >= 70) return "warm";
  return "calm";
}

/** The sentence a failed command shows in its row. A relaunching app is not a
    failure: the next snapshot will carry the result. */
export function commandFailureMessage(cause: Cause.Cause<unknown>): string {
  const error = Cause.squash(cause) as {
    readonly _tag?: string;
    readonly error?: string;
    readonly restarting?: boolean;
    readonly message?: string;
  } | null;
  if (error && error._tag === "InfinitusCommandFailed") {
    if (error.restarting === true)
      return "Infinitus is relaunching; the change lands with the next update.";
    return error.error && error.error.trim().length > 0
      ? error.error
      : "Infinitus refused the command.";
  }
  if (error && error._tag === "InfinitusUnavailable")
    return "Infinitus is not running on this Mac.";
  return error && typeof error.message === "string" && error.message.trim().length > 0
    ? error.message
    : "The command did not reach the Mac.";
}

/** What the home header's chip says for one Mac: the active account and its
    fullest window, or "limited" in the hot tone while every unheld account of
    its fleet is at a limit (#706). Nothing while the first snapshot is in
    flight; an unavailable app still earns a muted chip, so the tap leads to
    the reason. */
export interface HomeChipModel {
  readonly label: string;
  readonly pct: number | null;
  readonly tone: "calm" | "warm" | "hot" | "off";
  readonly limited: boolean;
}

export function homeChip(snapshot: InfinitusSnapshot | null, nowMs: number): HomeChipModel | null {
  if (snapshot === null) return null;
  if (!snapshot.available) return { label: "Infinitus", pct: null, tone: "off", limited: false };
  for (const fleet of snapshot.fleets) {
    const active = infinitusActiveAccount(fleet);
    if (active === null) continue;
    const row = buildFleetSection(fleet).rows.find(
      (candidate) => candidate.number === active.number,
    );
    const pct = row && row.windows.length > 0 ? Math.max(...row.windows.map((w) => w.pct)) : null;
    const limited = exhaustedBand(fleet, nowMs) !== null;
    return {
      label: infinitusAccountLabel(active),
      pct,
      tone: limited ? "hot" : pct === null ? "calm" : windowTone(pct),
      limited,
    };
  }
  return null;
}

/** The Mac the chip follows: the environment the home list is filtered to
    when that is a Mac, else the first Mac paired. */
export function chipEnvironment(
  selectedEnvironmentId: EnvironmentId | null,
  macs: ReadonlyArray<InfinitusMac>,
): InfinitusMac | null {
  if (selectedEnvironmentId !== null) {
    const selected = macs.find((mac) => mac.environmentId === selectedEnvironmentId);
    if (selected !== undefined) return selected;
  }
  return macs[0] ?? null;
}
