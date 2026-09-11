import { createFileRoute } from "@tanstack/react-router";

import { InfinitusDesktopCard } from "../components/settings/infinitus/InfinitusDesktopCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsInfinitusRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["display", "themes", "about"]}
      title="Infinitus"
      footer={<InfinitusDesktopCard />}
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/")({
  component: SettingsInfinitusRoute,
});
