import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

/** #747 step 1: the native Animations pane as a web page — rendered from the
    catalog's `animations` section, so it fills in as the native side adds
    rows; until then the page says the build has none. */
function SettingsInfinitusAnimationsRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["animations"]} title="Animations" />;
}

export const Route = createFileRoute("/settings/infinitus/animations")({
  component: SettingsInfinitusAnimationsRoute,
});
