import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { useEffect, useRef } from "react";

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
import { useStableCallback } from "./useStableCallback";

/**
 * Display prefs and account names across machines, via the desktop, the one process holding every
 * paired environment. Rules: `settingsSync.logic.ts`; traps: `docs/internals/settings-sync.md`.
 *
 * Returns the machines to watch: the caller mounts one feeder per machine (hooks cannot loop) and
 * reports snapshots through `report`.
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
  const machines = primaryRunsInfinitus
    ? syncMachines(
        environments,
        (environmentId) =>
          serverConfigs.get(environmentId)?.environment.capabilities.infinitus === true,
      )
    : [];
  // A pass spans several awaits; each round reads the machines as they are then.
  const readMachines = useStableCallback(() => machines);

  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const snapshots = useRef(new Map<EnvironmentId, InfinitusSnapshot | null>());
  const state = useRef<SyncState>(INITIAL_SYNC_STATE);

  // One pass at a time; a pass asked for while one runs follows it.
  const inFlight = useRef(false);
  const again = useRef(false);
  const runPasses = async () => {
    do {
      again.current = false;
      const pass = alignPass(state.current, readMachines(), snapshots.current);
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
  };
  const sync = useStableCallback(async () => {
    if (inFlight.current) {
      again.current = true;
      return;
    }
    inFlight.current = true;
    await runPasses().finally(() => {
      inFlight.current = false;
    });
  });

  const report = (environmentId: EnvironmentId, snapshot: InfinitusSnapshot | null) => {
    snapshots.current.set(environmentId, snapshot);
    state.current = observe(state.current, environmentId, environmentId === primaryId, snapshot);
    void sync();
  };

  // A machine that left the list starts over when it returns; one that
  // arrived or reconnected is aligned on the next pass.
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- forgets machines that left and runs an alignment pass of engine commands over the socket when the machine list changes
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
