import type { DesktopCaptureGestureFailure } from "@t3tools/contracts";

import type { ActiveProjectRef } from "./useCaptures";

/**
 * The desktop's capture gesture (#433 slice 2) lands while the user is in
 * another app: the text goes to the routed thread's project, else to the
 * last project a gesture reached this session, else it waits for one.
 */
export function resolveCaptureGestureProject(
  active: ActiveProjectRef | null,
  last: ActiveProjectRef | null,
): ActiveProjectRef | null {
  return active ?? last;
}

export function captureGestureFailureMessage(reason: DesktopCaptureGestureFailure): string {
  switch (reason) {
    case "accessibility":
      return "Allow this app under System Settings › Privacy & Security › Accessibility, then try again.";
    case "no-focus":
      return "The front app has no focused text field to read a selection from.";
    case "unsupported":
      return "The front app does not expose its selection to Accessibility.";
    case "timeout":
      return "Reading the selection took too long.";
    case "helper":
      return "The selection could not be read.";
  }
}
