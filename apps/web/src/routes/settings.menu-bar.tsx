import { createFileRoute } from "@tanstack/react-router";

import { InfinitusDesktopCard } from "../components/settings/infinitus/InfinitusDesktopCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

function SettingsMenuBarRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["display", "themes", "about"]}
      title="Menu bar"
      footer={<InfinitusDesktopCard />}
    />
  );
}

export const Route = createFileRoute("/settings/menu-bar")({
  component: SettingsMenuBarRoute,
});
