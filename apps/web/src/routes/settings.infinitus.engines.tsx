import { createFileRoute } from "@tanstack/react-router";

import { InfinitusEnginesPanel } from "../components/settings/infinitus/InfinitusEnginesPanel";

function SettingsInfinitusEnginesRoute() {
  return <InfinitusEnginesPanel />;
}

export const Route = createFileRoute("/settings/infinitus/engines")({
  component: SettingsInfinitusEnginesRoute,
});
