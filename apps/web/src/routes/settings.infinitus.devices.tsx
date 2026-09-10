import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusDevicesRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["devices"]} title="Devices" />;
}

export const Route = createFileRoute("/settings/infinitus/devices")({
  component: SettingsInfinitusDevicesRoute,
});
