import { createFileRoute } from "@tanstack/react-router";

import { InfinitusProfilesPanel } from "../components/settings/infinitus/InfinitusProfilesPanel";

function SettingsInfinitusProfilesRoute() {
  return <InfinitusProfilesPanel />;
}

export const Route = createFileRoute("/settings/infinitus/profiles")({
  component: SettingsInfinitusProfilesRoute,
});
