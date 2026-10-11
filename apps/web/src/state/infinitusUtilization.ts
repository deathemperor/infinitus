import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot, InfinitusUtilization } from "@infinitus/contracts/infinitus";
import { decodeUtilization } from "@infinitus/client-runtime/state/infinitusUtilization";
import * as Option from "effect/Option";
import { AsyncResult, Atom } from "effect/reactivity";
import { useCallback } from "react";

import { appAtomRegistry } from "../rpc/atomRegistry";
import { infinitusEnvironment } from "./infinitus";
import { environmentPresentations } from "./presentation";
import { formatEnvironmentQueryError } from "./query";
import { environmentServerConfigsAtom } from "./server";

/** One machine's answer to `utilization --days n` on the Utilization page
    (#1581). Exactly one of `missing`, `error`, `utilization` is set once the
    machine has answered; all three are null while `isPending`. */
export interface EnvironmentUtilizationStatus {
  readonly environmentId: EnvironmentId;
  readonly label: string;
  /** Nothing has answered yet: the snapshot, or the reply it unlocked. */
  readonly isPending: boolean;
  /** A reply is in flight, first or re-read; what the refresh icon spins on. */
  readonly waiting: boolean;
  /** The machine's snapshot, for the aliases its fleets show. */
  readonly snapshot: InfinitusSnapshot | null;
  /** Why the machine cannot be asked: the app is not running, or its build
      lacks the verb. */
  readonly missing: string | null;
  /** The reply failed or could not be read. */
  readonly error: string | null;
  readonly utilization: InfinitusUtilization | null;
}

export const UTILIZATION_NEEDS_NEWER_APP =
  "History and the run rate need a newer Infinitus app (the utilization verb).";
const UTILIZATION_UNREADABLE = "The utilization reply could not be read.";

const utilizationInput = (days: string) =>
  ({ command: "utilization", args: [], options: { days } }) as const;

/**
 * Every connected environment that runs Infinitus, each asked `utilization`
 * for the range, the way the Usage page reads every environment's summary
 * (`state/usage.ts`). One atom per range, so switching ranges keeps the
 * other's replies warm; the environments' own query atoms are shared with
 * any other reader of the same range.
 */
const utilizationByDaysAtom = Atom.family((days: string) =>
  Atom.make((get): ReadonlyArray<EnvironmentUtilizationStatus> => {
    const presentations = get(environmentPresentations.presentationsAtom);
    const serverConfigs = get(environmentServerConfigsAtom);
    const statuses: EnvironmentUtilizationStatus[] = [];
    for (const [environmentId, presentation] of presentations) {
      if (serverConfigs.get(environmentId)?.environment.capabilities.infinitus !== true) continue;
      const label = presentation.entry.target.label;
      const base = {
        environmentId,
        label,
        isPending: false,
        waiting: false,
        snapshot: null,
        missing: null,
        error: null,
        utilization: null,
      };
      // A machine that is away never answers: say so rather than read forever.
      if (presentation.connection.phase !== "connected") {
        statuses.push({ ...base, missing: "Not connected." });
        continue;
      }
      const snapshotResult = get(infinitusEnvironment.snapshot({ environmentId, input: {} }));
      const snapshot = Option.getOrNull(AsyncResult.value(snapshotResult));
      if (snapshot === null) {
        statuses.push(
          snapshotResult._tag === "Failure"
            ? { ...base, error: formatEnvironmentQueryError(snapshotResult.cause) }
            : { ...base, isPending: true, waiting: snapshotResult.waiting },
        );
        continue;
      }
      if (!snapshot.available) {
        const reason = snapshot.unavailableReason;
        statuses.push({
          ...base,
          snapshot,
          missing: `Infinitus is not running on this machine${reason === undefined ? "" : ` (${reason})`}.`,
        });
        continue;
      }
      if (!snapshot.commands.some((command) => command.name === "utilization")) {
        statuses.push({ ...base, snapshot, missing: UTILIZATION_NEEDS_NEWER_APP });
        continue;
      }
      const result = get(
        infinitusEnvironment.utilization({ environmentId, input: utilizationInput(days) }),
      );
      const reply = Option.getOrNull(AsyncResult.value(result));
      const asked = { ...base, snapshot, waiting: result.waiting };
      if (result._tag === "Failure") {
        statuses.push({ ...asked, error: formatEnvironmentQueryError(result.cause) });
        continue;
      }
      if (reply === null) {
        statuses.push({ ...asked, isPending: true });
        continue;
      }
      const utilization = decodeUtilization(reply.result);
      statuses.push(
        utilization === null
          ? { ...asked, error: UTILIZATION_UNREADABLE }
          : { ...asked, utilization },
      );
    }
    return statuses;
  }).pipe(Atom.withLabel(`web-infinitus-utilization:days:${days}`)),
);

/** Every Infinitus environment's `utilization` for the range, and a refresh
    that re-asks each one that has the verb. */
export function useEnvironmentUtilizations(days: string): {
  readonly statuses: ReadonlyArray<EnvironmentUtilizationStatus>;
  readonly refresh: () => void;
} {
  const statuses = useAtomValue(utilizationByDaysAtom(days));
  const refresh = useCallback(() => {
    for (const status of statuses) {
      if (status.snapshot === null || status.missing !== null) continue;
      appAtomRegistry.refresh(
        infinitusEnvironment.utilization({
          environmentId: status.environmentId,
          input: utilizationInput(days),
        }),
      );
    }
  }, [days, statuses]);
  return { statuses, refresh };
}
