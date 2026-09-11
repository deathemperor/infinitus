import { createFileRoute } from "@tanstack/react-router";

import { InfinitusDesktopCard } from "../components/settings/infinitus/InfinitusDesktopCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";
import { InfinitusResumeCard } from "../components/settings/infinitus/InfinitusResumeCard";

function SettingsInfinitusRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["display", "themes", "about"]}
      title="Infinitus"
      footer={
        <>
          <InfinitusResumeCard />
          <InfinitusDesktopCard />
        </>
      }
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/")({
  component: SettingsInfinitusRoute,
});
