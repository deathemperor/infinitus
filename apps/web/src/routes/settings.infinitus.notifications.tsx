import { createFileRoute } from "@tanstack/react-router";

import { DesktopBadgeSettings } from "../components/settings/DesktopBadgeSettings";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusNotificationsRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["push"]}
      title="Notifications"
      lead={<DesktopBadgeSettings />}
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/notifications")({
  component: SettingsInfinitusNotificationsRoute,
});
