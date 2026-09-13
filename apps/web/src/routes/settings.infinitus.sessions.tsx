import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

/** Session priority mode's knobs (#616, #743) as a web page: whatever rows the
    catalog's `priority` section carries — the mode, and the two thresholds
    native's headroom verdict binds on. Builds before the Mac's session sweep
    (#1041) file the same three keys under `sessions`, so both slugs are read. */
function SettingsInfinitusSessionsRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["priority", "sessions"]} title="Priority" />;
}

export const Route = createFileRoute("/settings/infinitus/sessions")({
  component: SettingsInfinitusSessionsRoute,
});
