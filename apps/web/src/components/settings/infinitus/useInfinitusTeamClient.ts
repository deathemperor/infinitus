import { useAuth } from "@clerk/react";
import { makeInfinitusTeamClient } from "@infinitus/client-runtime/relay/infinitusTeam";
import { useMemo } from "react";

import { resolveCloudPublicConfig, resolveRelayClerkTokenOptions } from "../../../cloud/publicConfig";

/** The relay's team client for the signed-in user (#1592); the token is
    read per call, so a session that lapses answers `signedOut`. Only under
    a Clerk provider: the pane checks `hasCloudPublicConfig()` first. */
export function useInfinitusTeamClient() {
  const { getToken } = useAuth();
  const relayUrl = resolveCloudPublicConfig().relayUrl ?? "";
  return useMemo(
    () =>
      makeInfinitusTeamClient({
        relayUrl,
        readClerkToken: () => getToken(resolveRelayClerkTokenOptions()),
      }),
    [getToken, relayUrl],
  );
}
