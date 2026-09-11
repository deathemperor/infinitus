import { useState } from "react";

import { usePrimaryEnvironment } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import {
  launchButtonLabel,
  launchNotice,
  launchPhaseAfter,
  type LaunchPhase,
} from "./launch.logic";

/**
 * "Launch Infinitus" for every unavailable state (#654): asks the server's
 * host to open the menu-bar app. Drawn only when that host is a Mac — the
 * only place the app runs — and the page it sits on already knows the socket
 * is quiet, so the button never has to say so itself.
 */
export function InfinitusLaunchButton({ className }: { readonly className?: string }) {
  const environment = usePrimaryEnvironment();
  const environmentId = environment?.environmentId ?? null;
  const os = environment?.serverConfig?.environment.platform.os;
  const launch = useAtomCommand(infinitusEnvironment.launch, { reportFailure: false });
  const [phase, setPhase] = useState<LaunchPhase>({ kind: "idle" });

  if (os !== "darwin" || environmentId === null) return null;

  const notice = launchNotice(phase);
  return (
    <div className={className}>
      <Button
        size="sm"
        variant="outline"
        disabled={phase.kind === "launching"}
        onClick={() => {
          setPhase({ kind: "launching" });
          void launch({ environmentId, input: {} }).then((result) =>
            setPhase(launchPhaseAfter(result)),
          );
        }}
      >
        {launchButtonLabel(phase)}
      </Button>
      {notice === null ? null : (
        <p role="status" className="mt-2 text-muted-foreground text-xs">
          {notice}
        </p>
      )}
    </div>
  );
}
