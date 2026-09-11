import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";

import { environmentServerConfigsAtom } from "../../state/server";
import { threadReadyForReview } from "./prHeader.logic";

/** Whether the thread list row should read "Ready for review" (#269 F): its
    current linked pull request waits on a reviewer. Reads the snapshot the
    server pushes with the thread, so no request per row. */
export function useThreadReadyForReview(thread: EnvironmentThreadShell): boolean {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const supportsLinks =
    configs.get(thread.environmentId)?.environment.capabilities.threadPullRequests === true;
  return threadReadyForReview(thread.pullRequests, supportsLinks);
}
