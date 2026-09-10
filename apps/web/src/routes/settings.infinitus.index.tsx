import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["display", "themes", "about"]} title="Infinitus" />;
}

export const Route = createFileRoute("/settings/infinitus/")({
  component: SettingsInfinitusRoute,
});
