import { createFileRoute } from "@tanstack/react-router";

import { InfinitusPrefsPanel } from "../components/settings/infinitus/InfinitusPrefsPanel";

/** Thread priority mode's knobs (#616, #743) as a web page: whatever rows the
    catalog's `priority` section carries — the mode, and the two thresholds
    native's headroom verdict binds on. The Mac files them there since #1069;
    a build before that answers `sessions`, so both slugs are read. */
function SettingsPriorityRoute() {
  return <InfinitusPrefsPanel sectionSlugs={["priority", "sessions"]} title="Priority" />;
}

export const Route = createFileRoute("/settings/priority")({
  component: SettingsPriorityRoute,
});
