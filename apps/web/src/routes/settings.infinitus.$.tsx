import { createFileRoute, redirect } from "@tanstack/react-router";

import { redirectedInfinitusSettingsPath } from "../components/settings/infinitus/settingsInfinitusRedirect.logic";

/** The old `/settings/infinitus[/…]` group: every path redirects to the page's
    top-level route, search (Engines' `environmentId`) kept. */
export const Route = createFileRoute("/settings/infinitus/$")({
  beforeLoad: ({ params }) => {
    throw redirect({
      to: redirectedInfinitusSettingsPath(params._splat),
      search: true,
      replace: true,
    });
  },
});
