import { useInfinitusSettingsSync } from "../hooks/useInfinitusSettingsSync";
import { PeerSnapshotFeeder } from "./InfinitusPeerFleets";

/** Mounted once in the desktop app shell: keeps display prefs and account
    names the same on every machine this desktop is paired with, as the
    primary Mac's Devices switches ask. Desktop only — the shell's list of
    machines is what this needs. */
export function InfinitusSettingsSync() {
  const { machines, report } = useInfinitusSettingsSync();
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
