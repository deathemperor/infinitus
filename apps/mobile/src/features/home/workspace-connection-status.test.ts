import { describe, expect, it } from "vite-plus/test";

import type { WorkspaceState } from "../../state/workspaceModel";
import { workspaceConnectionStatusPresentation } from "./workspace-connection-status";

function workspaceState(overrides: Partial<WorkspaceState> = {}): WorkspaceState {
  return {
    isLoadingConnections: false,
    hasConnections: true,
    hasLoadedShellSnapshot: true,
    hasPendingShellSnapshot: false,
    hasSyncingConnectedEnvironment: false,
    hasReadyEnvironment: true,
    hasConnectingEnvironment: false,
    connectingEnvironments: [],
    connectionState: "connected",
    connectionError: null,
    shellSnapshotError: null,
    networkStatus: "online",
    ...overrides,
  };
}

describe("workspace connection status", () => {
  it.each([
    ["reconnecting", "Could not reach sleeping laptop"],
    ["error", "Could not reach sleeping laptop"],
  ] as const)(
    "keeps the brand while a secondary environment is %s (%s)",
    (connectionState, connectionError) => {
      const state = workspaceState({
        hasConnectingEnvironment: connectionState !== "error",
        hasPendingShellSnapshot: true,
        connectionError,
        connectingEnvironments:
          connectionState === "error"
            ? []
            : [
                {
                  environmentId: "environment-2" as never,
                  environmentLabel: "Sleeping laptop",
                  displayUrl: "",
                  isRelayManaged: false,
                  isEnabled: true,
                  connectionState,
                  connectionError,
                  connectionErrorTraceId: null,
                },
              ],
      });

      expect(workspaceConnectionStatusPresentation(state)).toBeNull();
    },
  );

  it("shows connected shell catch-up even while a secondary environment is unreachable", () => {
    const state = workspaceState({
      hasSyncingConnectedEnvironment: true,
      hasPendingShellSnapshot: true,
      hasConnectingEnvironment: true,
      connectionError: "Could not reach sleeping laptop",
      connectingEnvironments: [
        {
          environmentId: "environment-2" as never,
          environmentLabel: "Sleeping laptop",
          displayUrl: "",
          isRelayManaged: false,
          isEnabled: true,
          connectionState: "reconnecting",
          connectionError: "Could not reach sleeping laptop",
          connectionErrorTraceId: null,
        },
      ],
    });

    expect(workspaceConnectionStatusPresentation(state)).toEqual({
<<<<<<< HEAD
      label: "Reconnecting to Julius’s Mac mini",
      showsProgress: true,
    });
  });

  it("keeps the retry spinner when the last attempt recorded a failure", () => {
    const state = workspaceState({
      hasConnectingEnvironment: true,
      hasReadyEnvironment: false,
      connectionError: "Could not reach HyperNovae",
      connectingEnvironments: [
        {
          environmentId: "environment-1" as never,
          environmentLabel: "HyperNovae",
          displayUrl: "",
          isRelayManaged: false,
          isEnabled: true,
          connectionState: "reconnecting",
          connectionError: "Could not reach HyperNovae",
          connectionErrorTraceId: null,
        },
      ],
    });

    expect(workspaceConnectionStatusPresentation(state)).toEqual({
      label: "Reconnecting to HyperNovae",
      showsProgress: true,
    });
  });

  it("surfaces connection errors before the generic disconnected fallback", () => {
    const state = workspaceState({
      connectionError: "Could not reach Julius’s Mac mini",
      hasLoadedShellSnapshot: false,
      hasReadyEnvironment: false,
    });

    expect(workspaceConnectionStatusPresentation(state)).toEqual({
      label: "Could not reach Julius’s Mac mini",
      showsProgress: false,
    });
  });

  it("shows shell catch-up while cached threads remain visible", () => {
    const state = workspaceState({ hasPendingShellSnapshot: true });

    expect(workspaceConnectionStatusPresentation(state)).toEqual({
=======
>>>>>>> upstream-sync-1dfb57287-upstream-renamed
      label: "Syncing threads...",
      showsProgress: true,
    });
  });
});
