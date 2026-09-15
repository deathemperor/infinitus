import { createFileRoute } from "@tanstack/react-router";

import { InfinitusTeamPanel } from "../components/settings/infinitus/InfinitusTeamPanel";

/** The Mac's team as a web page (#1313): members, a leader's requests and
    invite code, what you share, and Join with the code on the secret channel. */
function SettingsInfinitusTeamRoute() {
  return <InfinitusTeamPanel />;
}

export const Route = createFileRoute("/settings/infinitus/team")({
  component: SettingsInfinitusTeamRoute,
});
