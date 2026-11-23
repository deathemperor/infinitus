import { msg } from "gt-react-native";

import { m, type MessageResolver } from "../../i18n/messages";
import { runtimeConnectionErrorText } from "../connection/environmentStatusText";
import type { WorkspaceState } from "../../state/workspaceModel";

export interface WorkspaceConnectionStatusPresentation {
  readonly label: string;
  /** True while the label describes work in flight (connecting/syncing) — render a spinner. False when the label says we cannot connect — render a wifi-slash icon. */
  readonly showsProgress: boolean;
}

function shouldShowWorkspaceConnectionStatus(state: WorkspaceState): boolean {
  if (state.networkStatus === "offline") return true;
  if (state.hasReadyEnvironment) return state.hasSyncingConnectedEnvironment;
  return (
    state.connectionError !== null ||
    state.hasConnectingEnvironment ||
    state.hasPendingShellSnapshot ||
    (state.hasLoadedShellSnapshot && !state.hasReadyEnvironment)
  );
}

<<<<<<< HEAD
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
  if (state.hasReadyEnvironment && state.hasSyncingConnectedEnvironment) {
    return {
      label: state.hasLoadedShellSnapshot ? "Syncing threads..." : "Loading threads...",
      showsProgress: state.connectingEnvironments.length > 0 || state.hasPendingShellSnapshot,
    };
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
=======
function workspaceConnectionStatusLabel(state: WorkspaceState, resolve: MessageResolver): string {
  if (state.networkStatus === "offline") return resolve(msg("You are offline"));
  if (state.hasReadyEnvironment && state.hasSyncingConnectedEnvironment) {
    return state.hasLoadedShellSnapshot
      ? resolve(msg("Syncing threads..."))
      : resolve(msg("Loading threads..."));
  }
  if (state.connectingEnvironments.length === 1) {
    return resolve(
      msg("Reconnecting to {environment}", {
        environment: state.connectingEnvironments[0]!.environmentLabel,
      }),
    );
  }
  if (state.connectingEnvironments.length > 1) {
    return resolve(
      msg(
        "{count, plural, one {Reconnecting {count} environment} other {Reconnecting {count} environments}}",
        { count: state.connectingEnvironments.length },
      ),
    );
  }
  const connectionError = runtimeConnectionErrorText(state, resolve);
  if (connectionError !== null) return connectionError;
  if (state.hasPendingShellSnapshot) {
    return state.hasLoadedShellSnapshot
      ? resolve(msg("Syncing threads..."))
      : resolve(msg("Loading threads..."));
  }
  return resolve(msg("Not connected"));
>>>>>>> upstream-sync-780db269df-upstream-renamed
}

export function workspaceConnectionStatusPresentation(
  state: WorkspaceState,
  resolve: MessageResolver = m,
): WorkspaceConnectionStatusPresentation | null {
  if (!shouldShowWorkspaceConnectionStatus(state)) return null;
<<<<<<< HEAD
  return workspaceConnectionStatus(state);
=======
  return {
    label: workspaceConnectionStatusLabel(state, resolve),
    showsProgress:
      state.networkStatus !== "offline" &&
      (state.hasReadyEnvironment || state.connectionError === null) &&
      (state.connectingEnvironments.length > 0 || state.hasPendingShellSnapshot),
  };
>>>>>>> upstream-sync-780db269df-upstream-renamed
}
