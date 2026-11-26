import { createFileRoute } from "@tanstack/react-router";
import { DevicesSettingsPanel } from "../components/settings/IntegrationsSettings";
import { InfinitusCrashesCard } from "../components/settings/infinitus/InfinitusCrashesCard";
import { InfinitusPairingRequestsCard } from "../components/settings/infinitus/InfinitusPairingRequestsCard";
import {
  InfinitusPrefsPanel,
  useInfinitusEnvironment,
} from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsDevicesRoute() {
  const { capability } = useInfinitusEnvironment();
  return (
    <DevicesSettingsPanel>
      {capability === true ? (
        <InfinitusPrefsPanel
          contained={false}
          sectionSlugs={["devices"]}
          title="Paired devices"
          lead={<InfinitusPairingRequestsCard />}
          footer={<InfinitusCrashesCard />}
        />
      ) : null}
    </DevicesSettingsPanel>
  );
}

export const Route = createFileRoute("/_chat/settings/devices")({
  component: SettingsDevicesRoute,
});
