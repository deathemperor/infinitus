import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

/** #747 step 1: the native Themes pane as a web page — whatever rows the
    catalog's `themes` section carries (one today; the picker's rows follow
    from the native side). */
function SettingsInfinitusThemesRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["themes"]} title="Themes" />;
}

export const Route = createFileRoute("/settings/infinitus/themes")({
  component: SettingsInfinitusThemesRoute,
});
