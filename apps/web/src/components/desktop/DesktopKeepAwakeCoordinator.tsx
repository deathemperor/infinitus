import { useAtomValue } from "@effect/atom-react";
import { useEffect } from "react";

import { useClientSettings } from "../../hooks/useSettings";
import { keepAwakeWanted } from "../../lib/desktopKeepAwake.logic";
import { useThreadShells } from "../../state/entities";
import { primaryEnvironmentIdAtom } from "../../state/primaryEnvironment";

/**
 * Keeps the desktop shell's power-save blocker in step with the threads
 * (#1075): held while any thread on this window's own server has a turn
 * starting or running, released when the last one ends, on unmount, and
 * once on mount (a reload leaves the shell holding whatever the last page
 * asked for). Mounted once from `__root.tsx`; nothing rendered; nothing on
 * a shell without the bridge.
 */
export function DesktopKeepAwakeCoordinator() {
  const setKeepAwake = window.desktopBridge?.setKeepAwake;
  const shells = useThreadShells();
  const enabled = useClientSettings((settings) => settings.desktopKeepAwake);
  const primaryEnvironmentId = useAtomValue(primaryEnvironmentIdAtom);
  const wanted = keepAwakeWanted({ enabled, primaryEnvironmentId, shells });

  useEffect(() => {
    if (setKeepAwake === undefined) return;
    void setKeepAwake(wanted);
    if (!wanted) return;
    return () => {
      void setKeepAwake(false);
    };
  }, [setKeepAwake, wanted]);

  return null;
}
