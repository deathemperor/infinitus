import type { WorkspaceState } from "../../state/workspaceModel";

export interface WorkspaceConnectionStatusPresentation {
  readonly label: string;
  /** True while the label describes work in flight (connecting/syncing) — render a spinner. False when the label says we cannot connect — render a wifi-slash icon. */
  readonly showsProgress: boolean;
}

function shouldShowWorkspaceConnectionStatus(state: WorkspaceState): boolean {
  return (
    state.networkStatus === "offline" ||
    state.connectionError !== null ||
    state.hasConnectingEnvironment ||
    state.hasPendingShellSnapshot ||
    (state.hasLoadedShellSnapshot && !state.hasReadyEnvironment)
  );
}

/**
 * Label and icon are decided together so they can never disagree: a retry in
 * flight reads "Reconnecting" beside a spinner, and the wifi-slash icon is
 * reserved for the states whose label says we cannot connect. A recorded
 * failure does not stop the spinner — the supervisor is still retrying.
 */
function workspaceConnectionStatus(state: WorkspaceState): WorkspaceConnectionStatusPresentation {
  if (state.networkStatus === "offline") {
    return { label: "You are offline", showsProgress: false };
  }
  if (state.connectingEnvironments.length === 1) {
    return {
      label: `Reconnecting to ${state.connectingEnvironments[0]!.environmentLabel}`,
      showsProgress: true,
    };
  }
  if (state.connectingEnvironments.length > 1) {
    return {
      label: `Reconnecting ${state.connectingEnvironments.length} environments`,
      showsProgress: true,
    };
  }
  if (state.connectionError !== null) {
    return { label: state.connectionError, showsProgress: false };
  }
  if (state.hasPendingShellSnapshot) {
    return {
      label: state.hasLoadedShellSnapshot ? "Syncing threads..." : "Loading threads...",
      showsProgress: true,
    };
  }
  return { label: "Not connected", showsProgress: false };
}

/** Header-title presentation of the connection state, or null while connected. */
export function workspaceConnectionStatusPresentation(
  state: WorkspaceState,
): WorkspaceConnectionStatusPresentation | null {
  if (!shouldShowWorkspaceConnectionStatus(state)) return null;
  return workspaceConnectionStatus(state);
}
