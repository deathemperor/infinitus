import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPairPhoneCard } from "../components/settings/infinitus/InfinitusPairPhoneCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusDevicesRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["devices"]}
      title="Devices"
      footer={<InfinitusPairPhoneCard />}
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/devices")({
  component: SettingsInfinitusDevicesRoute,
});
