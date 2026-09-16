import { WS_METHODS } from "@infinitus/contracts";
import { createEnvironmentRpcCommand } from "@infinitus/client-runtime/state/runtime";

import { connectionAtomRuntime } from "../../connection/runtime";

/** `pullRequests.runAction`: the same route the web's PR panel runs its
    buttons through (#269). The phone sends only `ready` today; the server
    re-syncs the thread's link afterwards, so the header's phase follows. */
export const runPullRequestAction = createEnvironmentRpcCommand(connectionAtomRuntime, {
  label: "environment-data:pull-requests:run-action",
  tag: WS_METHODS.pullRequestsRunAction,
});
