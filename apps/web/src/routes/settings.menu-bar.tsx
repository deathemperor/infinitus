import { createFileRoute } from "@tanstack/react-router";

import { InfinitusDesktopCard } from "../components/settings/infinitus/InfinitusDesktopCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";
import { InfinitusResumeCard } from "../components/settings/infinitus/InfinitusResumeCard";
import { InfinitusSlackCard } from "../components/settings/infinitus/InfinitusSlackCard";

function SettingsMenuBarRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["display", "themes", "about"]}
      title="Menu bar"
      footer={
        <>
          <InfinitusResumeCard />
          <InfinitusSlackCard />
          <InfinitusDesktopCard />
        </>
      }
    />
  );
}

export const Route = createFileRoute("/settings/menu-bar")({
  component: SettingsMenuBarRoute,
});
