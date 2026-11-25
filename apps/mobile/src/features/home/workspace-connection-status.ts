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

/**
 * Label and icon are decided together so they can never disagree: a retry in
 * flight reads "Reconnecting" beside a spinner, and the wifi-slash icon is
 * reserved for the states whose label says we cannot connect. A recorded
 * failure does not stop the spinner — the supervisor is still retrying.
 */
function workspaceConnectionStatus(
  state: WorkspaceState,
  resolve: MessageResolver,
): WorkspaceConnectionStatusPresentation {
  if (state.networkStatus === "offline") {
    return { label: resolve(msg("You are offline")), showsProgress: false };
  }
  if (state.hasReadyEnvironment && state.hasSyncingConnectedEnvironment) {
    return {
      label: state.hasLoadedShellSnapshot
        ? resolve(msg("Syncing threads..."))
        : resolve(msg("Loading threads...")),
      showsProgress: state.connectingEnvironments.length > 0 || state.hasPendingShellSnapshot,
    };
  }
  if (state.connectingEnvironments.length === 1) {
    return {
      label: resolve(
        msg("Reconnecting to {environment}", {
          environment: state.connectingEnvironments[0]!.environmentLabel,
        }),
      ),
      showsProgress: true,
    };
  }
  if (state.connectingEnvironments.length > 1) {
    return {
      label: resolve(
        msg(
          "{count, plural, one {Reconnecting {count} environment} other {Reconnecting {count} environments}}",
          { count: state.connectingEnvironments.length },
        ),
      ),
      showsProgress: true,
    };
  }
  const connectionError = runtimeConnectionErrorText(state, resolve);
  if (connectionError !== null) {
    return { label: connectionError, showsProgress: false };
  }
  if (state.hasPendingShellSnapshot) {
    return {
      label: state.hasLoadedShellSnapshot
        ? resolve(msg("Syncing threads..."))
        : resolve(msg("Loading threads...")),
      showsProgress: true,
    };
  }
  return { label: resolve(msg("Not connected")), showsProgress: false };
}

export function workspaceConnectionStatusPresentation(
  state: WorkspaceState,
  resolve: MessageResolver = m,
): WorkspaceConnectionStatusPresentation | null {
  if (!shouldShowWorkspaceConnectionStatus(state)) return null;
  return workspaceConnectionStatus(state, resolve);
}
