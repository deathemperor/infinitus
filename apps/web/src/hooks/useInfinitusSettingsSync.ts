import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { useCallback, useEffect, useMemo, useRef } from "react";

import { useEnvironments, usePrimaryEnvironment } from "../state/environments";
import { infinitusEnvironment } from "../state/infinitus";
import { environmentServerConfigsAtom } from "../state/server";
import { useAtomCommand } from "../state/use-atom-command";
import {
  alignPass,
  forget,
  INITIAL_SYNC_STATE,
  observe,
  syncMachines,
  type SyncMachine,
  type SyncState,
} from "./settingsSync.logic";

/**
 * Display prefs and account names across machines, through the desktop: the
 * one process that holds every paired environment. Each machine's snapshot
 * already carries its prefs and its fleets, and `prefs set` and `rename`
 * already exist, so nothing new crosses the socket. The rules live in
 * `settingsSync.logic.ts` (`observe`, `alignPass`), where two desktops can be
 * replayed against the same machines; this hook only feeds them snapshots and
 * runs the commands they hand back. The switches are the primary Mac's
 * `sync_settings` and `sync_account_names`. Rules and traps:
 * `docs/internals/settings-sync.md`.
 *
 * Returns the machines to watch: the caller mounts one feeder per machine
 * (hooks cannot loop) and reports each snapshot through `report`.
 */
export function useInfinitusSettingsSync(): {
  readonly machines: ReadonlyArray<SyncMachine>;
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
        ? syncMachines(
            environments,
            (environmentId) =>
              serverConfigs.get(environmentId)?.environment.capabilities.infinitus === true,
          )
        : [],
    [environments, primaryRunsInfinitus, serverConfigs],
  );
  const machinesRef = useRef(machines);
  useEffect(() => {
    machinesRef.current = machines;
  }, [machines]);

  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const snapshots = useRef(new Map<EnvironmentId, InfinitusSnapshot | null>());
  const state = useRef<SyncState>(INITIAL_SYNC_STATE);

  // One pass at a time; a pass asked for while one runs follows it.
  const inFlight = useRef(false);
  const again = useRef(false);
  const sync = useCallback(async () => {
    if (inFlight.current) {
      again.current = true;
      return;
    }
    inFlight.current = true;
    try {
      do {
        again.current = false;
        const pass = alignPass(state.current, machinesRef.current, snapshots.current);
        state.current = pass.state;
        for (const work of pass.work) {
          for (const command of work.commands) {
            await runCommand({
              environmentId: work.environmentId,
              input: { command: command.command, args: command.args, options: {} },
            });
          }
        }
      } while (again.current);
    } finally {
      inFlight.current = false;
    }
  }, [runCommand]);

  const report = useCallback(
    (environmentId: EnvironmentId, snapshot: InfinitusSnapshot | null) => {
      snapshots.current.set(environmentId, snapshot);
      state.current = observe(state.current, environmentId, environmentId === primaryId, snapshot);
      void sync();
    },
    [primaryId, sync],
  );

  // A machine that left the list starts over when it returns; one that
  // arrived or reconnected is aligned on the next pass.
  useEffect(() => {
    const present = new Set(machines.map((machine) => machine.environmentId));
    for (const environmentId of state.current.observed.keys()) {
      if (present.has(environmentId)) continue;
      state.current = forget(state.current, environmentId);
      snapshots.current.delete(environmentId);
    }
    if (machines.length > 0) void sync();
  }, [machines, sync]);

  return { machines, report };
}
