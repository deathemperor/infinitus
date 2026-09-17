import { createFileRoute } from "@tanstack/react-router";

import { InfinitusCrashesCard } from "../components/settings/infinitus/InfinitusCrashesCard";
import { InfinitusPairingRequestsCard } from "../components/settings/infinitus/InfinitusPairingRequestsCard";
import { InfinitusPairPhoneCard } from "../components/settings/infinitus/InfinitusPairPhoneCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusDevicesRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["devices"]}
      title="Devices"
      lead={<InfinitusPairingRequestsCard />}
      footer={
        <>
          <InfinitusPairPhoneCard />
          <InfinitusCrashesCard />
        </>
      }
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/devices")({
  component: SettingsInfinitusDevicesRoute,
});
