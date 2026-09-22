import type { EnvironmentId } from "@infinitus/contracts";
import {
  InfinitusPeerSyncReply,
  type InfinitusFleet,
  type InfinitusPeerSyncBody,
  type InfinitusPeerSyncCommand,
  type InfinitusPeerSyncResult,
  type InfinitusSnapshot,
} from "@infinitus/contracts/infinitus";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

/** The verb the desktop pushes with, and what it forwards back (#1545). */
export const PEER_SYNC_COMMAND = "peer-sync";

/** How long the popup's peers stay without a push before they go stale on
    the Mac, so a heartbeat well inside it keeps a quiet fleet alive. */
export const PEER_SYNC_HEARTBEAT_MS = 30_000;

/** The row actions the popup may ask another machine to run. The desktop is
    a relay with a list, not a blind one: nothing that carries a secret, adds
    an account or restarts an app ever goes through. */
const FORWARDABLE = new Set([
  "switch",
  "rotate",
  "hold",
  "unhold",
  "prefer",
  "auto-ignite",
  "rename",
  "remove",
  "refresh",
]);

export function forwardable(command: InfinitusPeerSyncCommand): boolean {
  return FORWARDABLE.has(command.command);
}

/** One other machine the loop feeds: connected environments that run
    Infinitus, minus the primary the popup belongs to. */
export interface PeerMachine {
  readonly environmentId: EnvironmentId;
  readonly label: string;
  readonly connected: boolean;
}

export function peerMachines(
  environments: ReadonlyArray<{
    readonly environmentId: EnvironmentId;
    readonly label: string;
    readonly connection: { readonly phase: string };
  }>,
  runsInfinitus: (environmentId: EnvironmentId) => boolean,
  primaryEnvironmentId: EnvironmentId | null,
): ReadonlyArray<PeerMachine> {
  return environments
    .filter(
      (environment) =>
        environment.environmentId !== primaryEnvironmentId &&
        runsInfinitus(environment.environmentId),
    )
    .map((environment) => ({
      environmentId: environment.environmentId,
      label: environment.label,
      connected: environment.connection.phase === "connected",
    }));
}

/** What the popup draws of a fleet, so a push happens when a row would
    change and not when only an age or a fetch stamp moved: a remote snapshot
    re-emits every few seconds with nothing but those moving, and each push
    re-renders the popup. */
export function fleetFingerprint(fleets: ReadonlyArray<InfinitusFleet> | null): string {
  if (fleets === null) return "";
  return fleets
    .map((fleet) => {
      const rows = fleet.accounts.map((account) => {
        const usage = usageWindows(account.usage);
        return [
          account.number,
          account.alias ?? "",
          account.email,
          account.plan ?? "",
          account.active ? 1 : 0,
          account.disabled ? 1 : 0,
          account.preferred ? 1 : 0,
          account.autoIgnite ? 1 : 0,
          account.usageStatus,
          usage,
        ].join("|");
      });
      return [
        fleet.key,
        fleet.activeNumber ?? "",
        fleet.nextCandidate ?? "",
        fleet.capabilities.join(","),
        rows.join(";"),
      ].join("#");
    })
    .join("\n");
}

/** The percentages of the windows the row draws, rounded to what the bars
    can show; the engine's opaque usage is read for just those. */
function usageWindows(usage: unknown): string {
  if (typeof usage !== "object" || usage === null) return "";
  const record = usage as Record<string, unknown>;
  const pct = (window: unknown): string => {
    if (typeof window !== "object" || window === null) return "";
    const value = (window as { pct?: unknown }).pct;
    return typeof value === "number" ? String(Math.round(value)) : "";
  };
  const scoped = Array.isArray(record.scoped) ? record.scoped.map(pct).join(",") : "";
  return `${pct(record.fiveHour)}/${pct(record.sevenDay)}/${pct(record.spend)}/${scoped}`;
}

export function peerSyncBody(
  machines: ReadonlyArray<PeerMachine>,
  snapshots: ReadonlyMap<EnvironmentId, InfinitusSnapshot | null>,
  results: ReadonlyArray<InfinitusPeerSyncResult>,
): InfinitusPeerSyncBody {
  return {
    machines: machines.map((machine) => {
      const snapshot = snapshots.get(machine.environmentId) ?? null;
      return {
        id: machine.environmentId,
        label: machine.label,
        // A machine whose app is offline has nothing the popup can draw.
        connected: machine.connected && snapshot?.available === true,
        fleets: snapshot?.available === true ? snapshot.fleets : null,
      };
    }),
    results,
  };
}

const decodeReply = Schema.decodeUnknownOption(InfinitusPeerSyncReply);

/** The commands the popup queued, or none for a reply this build cannot read. */
export function peerSyncReply(result: unknown): ReadonlyArray<InfinitusPeerSyncCommand> {
  const decoded = decodeReply(result);
  return Option.isSome(decoded) ? decoded.value.commands : [];
}

/** The outcome of a forwarded command as the popup wants it: the app's own
    refusal in its words, or a one-line reason the desktop could not forward. */
export function peerCommandResult(
  command: InfinitusPeerSyncCommand,
  outcome: { readonly ok: true } | { readonly ok: false; readonly error: string },
): InfinitusPeerSyncResult {
  return outcome.ok
    ? { id: command.id, ok: true }
    : { id: command.id, ok: false, error: outcome.error };
}
