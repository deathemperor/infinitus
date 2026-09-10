import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusNotificationsRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["push"]} title="Notifications" />;
}

export const Route = createFileRoute("/settings/infinitus/notifications")({
  component: SettingsInfinitusNotificationsRoute,
});
