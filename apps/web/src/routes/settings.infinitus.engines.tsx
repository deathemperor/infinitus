import { EnvironmentId } from "@t3tools/contracts";
import { createFileRoute } from "@tanstack/react-router";

import { useEnvironment } from "../state/environments";

import { InfinitusEnginesPanel } from "../components/settings/infinitus/InfinitusEnginesPanel";

function SettingsInfinitusEnginesRoute() {
  const { environmentId } = Route.useSearch();
  const environment = useEnvironment(environmentId ?? null);
  return (
    <InfinitusEnginesPanel
      key={environmentId ?? "primary"}
      {...(environmentId ? { environment } : {})}
    />
  );
}

export const Route = createFileRoute("/settings/infinitus/engines")({
  validateSearch: (raw: Record<string, unknown>): { environmentId?: EnvironmentId } =>
    typeof raw.environmentId === "string" && raw.environmentId.trim()
      ? { environmentId: EnvironmentId.make(raw.environmentId) }
      : {},
  component: SettingsInfinitusEnginesRoute,
});
