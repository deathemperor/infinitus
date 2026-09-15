import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";

import { serverEnvironment } from "../../state/server";
import { threadReadyForReview } from "./prHeader.logic";

/** Whether the thread list row should read "Ready for review" (#269 F): its
    current linked pull request waits on a reviewer. Reads the snapshot the
    server pushes with the thread, so no request per row, and the one
    capability flag through its environment's own atom with a selector (as
    upstream's `useThreadPr` does), so a row wakes only when that flag flips
    — not on every config change of every environment (phone audit 2026-09-15). */
export function useThreadReadyForReview(thread: EnvironmentThreadShell): boolean {
  const supportsLinks = useAtomValue(
    serverEnvironment.configValueAtom(thread.environmentId),
    (config) => config?.environment.capabilities.threadPullRequests === true,
  );
  return threadReadyForReview(thread.pullRequests, supportsLinks);
}
