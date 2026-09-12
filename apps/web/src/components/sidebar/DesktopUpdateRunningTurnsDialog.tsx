import type { DesktopUpdateState } from "@t3tools/contracts";
import { useRef } from "react";

import {
  getDesktopUpdateArmedDialog,
  getDesktopUpdateRunningTurnsDialog,
} from "../desktopUpdate.logic";
import {
  AlertDialog,
  AlertDialogClose,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogPopup,
  AlertDialogTitle,
} from "../ui/alert-dialog";
import { Button } from "../ui/button";

/** What the update button asked for: the install while turns run, or a look at the armed wait. */
export interface DesktopUpdateRunningTurnsDialogRequest {
  /** Running turns on the local backends; null while some backend's shells are still loading. */
  readonly count: number | null;
  /** "Install when they finish" is already armed: keep, cancel or skip the wait. */
  readonly armed: boolean;
}

/**
 * The install confirm while turns run (#829, the shape the plain install
 * confirm has): Later leaves the update for another click, "Install when
 * they finish" arms the button, "Install now" cuts the turns off. A click
 * on the armed button opens the same dialog to keep, cancel or skip the wait.
 */
export function DesktopUpdateRunningTurnsDialog({
  request,
  state,
  onClose,
  onInstallNow,
  onInstallWhenIdle,
  onCancelArm,
}: {
  readonly request: DesktopUpdateRunningTurnsDialogRequest | null;
  readonly state: Pick<DesktopUpdateState, "availableVersion" | "downloadedVersion">;
  readonly onClose: () => void;
  readonly onInstallNow: () => void;
  readonly onInstallWhenIdle: () => void;
  readonly onCancelArm: () => void;
}) {
  const copy =
    request === null
      ? null
      : request.armed
        ? getDesktopUpdateArmedDialog(request.count ?? 0)
        : getDesktopUpdateRunningTurnsDialog(request.count, state);
  // Enter takes the choice that keeps the turns alive; Escape is Later / Keep waiting.
  const safeChoiceRef = useRef<HTMLButtonElement>(null);
  const choose = (choice: () => void) => () => {
    onClose();
    choice();
  };

  return (
    <AlertDialog
      open={request !== null}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <AlertDialogPopup className="max-w-lg" initialFocus={safeChoiceRef}>
        <AlertDialogHeader>
          <AlertDialogTitle>{copy?.title}</AlertDialogTitle>
          {copy ? <AlertDialogDescription>{copy.description}</AlertDialogDescription> : null}
        </AlertDialogHeader>
        <AlertDialogFooter>
          {request?.armed ? (
            <>
              <Button variant="outline" onClick={choose(onCancelArm)}>
                Cancel the wait
              </Button>
              <Button variant="outline" onClick={choose(onInstallNow)}>
                Install now
              </Button>
              <Button ref={safeChoiceRef} onClick={onClose}>
                Keep waiting
              </Button>
            </>
          ) : request?.count === null ? (
            <>
              <Button ref={safeChoiceRef} variant="outline" onClick={onClose}>
                Later
              </Button>
              <Button onClick={choose(onInstallNow)}>Install now</Button>
            </>
          ) : (
            <>
              <AlertDialogClose render={<Button variant="outline" />}>Later</AlertDialogClose>
              <Button variant="outline" onClick={choose(onInstallNow)}>
                Install now
              </Button>
              <Button ref={safeChoiceRef} onClick={choose(onInstallWhenIdle)}>
                Install when they finish
              </Button>
            </>
          )}
        </AlertDialogFooter>
      </AlertDialogPopup>
    </AlertDialog>
  );
}
