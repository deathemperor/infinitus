import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusPeerSyncResult, InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import * as Cause from "effect/Cause";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { useEnvironments, usePrimaryEnvironment } from "../state/environments";
import { infinitusEnvironment } from "../state/infinitus";
import { useEnvironmentQuery } from "../state/query";
import { environmentServerConfigsAtom } from "../state/server";
import { useAtomCommand } from "../state/use-atom-command";
import {
  fleetFingerprint,
  forwardable,
  PEER_SYNC_COMMAND,
  PEER_SYNC_HEARTBEAT_MS,
  peerCommandResult,
  peerMachines,
  peerSyncBody,
  peerSyncReply,
  type PeerMachine,
} from "./peerFleets.logic";

/** What the socket said went wrong, in the words the popup will show. */
function failureMessage(cause: Cause.Cause<unknown>): string {
  const error: unknown = Cause.squash(cause);
  if (typeof error === "object" && error !== null) {
    const tagged = error as { readonly _tag?: unknown; readonly error?: unknown };
    if (tagged._tag === "InfinitusCommandFailed" && typeof tagged.error === "string") {
      return tagged.error;
    }
    if (error instanceof Error && error.message.trim() !== "") return error.message;
  }
  return "The command did not reach that machine.";
}

/**
 * The menu bar popup's other machines (#1545). The desktop is the one place
 * that holds every paired environment, so it feeds this Mac's app: each
 * remote machine's fleets go over `peer-sync` when a row would change, on a
 * heartbeat inside the app's silence window, and at once when the app's
 * status says a peer row is waiting on a command. The reply carries the row
 * actions the popup queued for those machines; each is forwarded verbatim
 * to that machine's server and its outcome pushed straight back.
 *
 * Returns the machines to feed: the caller mounts one `PeerSnapshotFeeder`
 * per machine (hooks cannot loop) and reports each snapshot through
 * `report`.
 */
export function useInfinitusPeerFleets(): {
  readonly machines: ReadonlyArray<PeerMachine>;
  readonly report: (environmentId: EnvironmentId, snapshot: InfinitusSnapshot | null) => void;
} {
  const primary = usePrimaryEnvironment();
  const primaryId = primary?.environmentId ?? null;
  const primaryRunsInfinitus = primary?.serverConfig?.environment.capabilities.infinitus === true;
  const { environments } = useEnvironments();
  const serverConfigs = useAtomValue(environmentServerConfigsAtom);
  const machines = useMemo(
    () =>
      primaryRunsInfinitus
        ? peerMachines(
            environments,
            (environmentId) =>
              serverConfigs.get(environmentId)?.environment.capabilities.infinitus === true,
            primaryId,
          )
        : [],
    [environments, primaryId, primaryRunsInfinitus, serverConfigs],
  );
  const machinesKey = machines
    .map((machine) => `${machine.environmentId}:${machine.connected ? 1 : 0}`)
    .join(",");

  const primaryQuery = useEnvironmentQuery(
    primaryId === null || !primaryRunsInfinitus || machines.length === 0
      ? null
      : infinitusEnvironment.snapshot({ environmentId: primaryId, input: {} }),
  );
  const pendingCommands = primaryQuery.data?.status?.peerCommandsPending ?? 0;

  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const snapshots = useRef(new Map<EnvironmentId, InfinitusSnapshot | null>());
  const fingerprints = useRef(new Map<EnvironmentId, string>());
  // Bumped when a row-visible field of any remote fleet changes.
  const [fleetsVersion, setFleetsVersion] = useState(0);
  const report = useCallback((environmentId: EnvironmentId, snapshot: InfinitusSnapshot | null) => {
    snapshots.current.set(environmentId, snapshot);
    const fingerprint = snapshot?.available === true ? fleetFingerprint(snapshot.fleets) : "";
    if (fingerprints.current.get(environmentId) === fingerprint) return;
    fingerprints.current.set(environmentId, fingerprint);
    setFleetsVersion((version) => version + 1);
  }, []);

  // One push at a time; a push asked for while one runs follows it.
  const inFlight = useRef(false);
  const again = useRef(false);
  const results = useRef<Array<InfinitusPeerSyncResult>>([]);
  const machinesRef = useRef(machines);
  machinesRef.current = machines;

  const sync = useCallback(async () => {
    if (primaryId === null) return;
    if (inFlight.current) {
      again.current = true;
      return;
    }
    inFlight.current = true;
    try {
      do {
        again.current = false;
        const body = peerSyncBody(machinesRef.current, snapshots.current, results.current);
        results.current = [];
        const answer = await runCommand({
          environmentId: primaryId,
          input: { command: PEER_SYNC_COMMAND, args: [], options: { body: JSON.stringify(body) } },
        });
        if (answer._tag === "Failure") return;
        const commands = peerSyncReply(answer.value.result);
        for (const command of commands) {
          const machine = machinesRef.current.find(
            (entry) => entry.environmentId === command.machine,
          );
          if (machine === undefined || !machine.connected) {
            results.current.push(
              peerCommandResult(command, { ok: false, error: "That machine is not connected." }),
            );
            continue;
          }
          if (!forwardable(command)) {
            results.current.push(
              peerCommandResult(command, {
                ok: false,
                error: `${command.command} cannot be run on another machine.`,
              }),
            );
            continue;
          }
          const outcome = await runCommand({
            environmentId: machine.environmentId,
            input: { command: command.command, args: command.args, options: command.options },
          });
          results.current.push(
            outcome._tag === "Success"
              ? peerCommandResult(command, { ok: true })
              : peerCommandResult(command, { ok: false, error: failureMessage(outcome.cause) }),
          );
        }
        // Outcomes go back at once: a row is waiting on each.
        if (results.current.length > 0) again.current = true;
      } while (again.current);
    } finally {
      inFlight.current = false;
    }
  }, [primaryId, runCommand]);

  // A change to push: the machine set, a connection, a row-visible field.
  useEffect(() => {
    if (machines.length === 0) return;
    void sync();
  }, [machinesKey, fleetsVersion, machines.length, sync]);

  // The app says a peer row is waiting: push now rather than on the clock.
  useEffect(() => {
    if (pendingCommands > 0) void sync();
  }, [pendingCommands, sync]);

  // The heartbeat keeps a quiet fleet alive on the Mac.
  useEffect(() => {
    if (machines.length === 0) return;
    const timer = setInterval(() => void sync(), PEER_SYNC_HEARTBEAT_MS);
    return () => clearInterval(timer);
  }, [machines.length, sync]);

  return { machines, report };
}
