import { createFileRoute } from "@tanstack/react-router";

import { DesktopNotificationSettings } from "../components/settings/DesktopNotificationSettings";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusNotificationsRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["push"]}
      title="Notifications"
      lead={<DesktopNotificationSettings />}
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/notifications")({
  component: SettingsInfinitusNotificationsRoute,
});
