import { createFileRoute } from "@tanstack/react-router";

import { ActivityPage } from "../components/activity/ActivityPage";

// `engines_` keeps this a sibling of the Engines route, drawn in Settings'
// own outlet, not inside the Engines panel.
export const Route = createFileRoute("/settings/engines_/activity")({
  component: ActivityPage,
});
