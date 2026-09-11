import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

/** Session priority mode's knobs (#616, #743) as a web page: whatever rows the
    catalog's `sessions` section carries — the mode, and the two thresholds
    native's headroom verdict binds on. */
function SettingsInfinitusSessionsRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["sessions"]} title="Sessions" />;
}

export const Route = createFileRoute("/settings/infinitus/sessions")({
  component: SettingsInfinitusSessionsRoute,
});
