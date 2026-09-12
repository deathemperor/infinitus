import { createFileRoute } from "@tanstack/react-router";

import { InfinitusDesktopCard } from "../components/settings/infinitus/InfinitusDesktopCard";
import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";
import { InfinitusResumeCard } from "../components/settings/infinitus/InfinitusResumeCard";
import { InfinitusSlackCard } from "../components/settings/infinitus/InfinitusSlackCard";

function SettingsInfinitusRoute() {
  return (
    <InfinitusPrefsPanel
      sectionSlugs={["display", "about"]}
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

export const Route = createFileRoute("/settings/infinitus/")({
  component: SettingsInfinitusRoute,
});
