import type { EnvironmentId } from "@infinitus/contracts";
import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { useEffect } from "react";

import { useInfinitusPeerFleets } from "../hooks/useInfinitusPeerFleets";
import { infinitusEnvironment } from "../state/infinitus";
import { useEnvironmentQuery } from "../state/query";

/** One machine's snapshot subscription, reported up to a loop (the peer
    fleets' and the settings sync's; the atom family shares the stream). */
export function PeerSnapshotFeeder({
  environmentId,
  connected,
  report,
}: {
  readonly environmentId: EnvironmentId;
  readonly connected: boolean;
  readonly report: (environmentId: EnvironmentId, snapshot: InfinitusSnapshot | null) => void;
}) {
  const query = useEnvironmentQuery(
    connected ? infinitusEnvironment.snapshot({ environmentId, input: {} }) : null,
  );
  const snapshot = query.data;
  useEffect(() => {
    report(environmentId, snapshot);
  }, [environmentId, report, snapshot]);
  return null;
}

/** Mounted once in the desktop app shell (#1545): feeds the menu bar popup
    every other machine's accounts and runs the row actions it queues for
    them. Desktop only — the popup is this Mac's, and the engine binary the
    shell owns is not what this needs, only the shell's list of machines. */
export function InfinitusPeerFleets() {
  const { machines, report } = useInfinitusPeerFleets();
  return (
    <>
      {machines.map((machine) => (
        <PeerSnapshotFeeder
          key={machine.environmentId}
          environmentId={machine.environmentId}
          connected={machine.connected}
          report={report}
        />
      ))}
    </>
  );
}
