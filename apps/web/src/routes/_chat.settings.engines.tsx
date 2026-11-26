import { EnvironmentId } from "@infinitus/contracts";
import { createFileRoute } from "@tanstack/react-router";

import { useEnvironment, usePrimaryEnvironmentId } from "../state/environments";

import { SettingsScopeProvider } from "../components/settings/SettingsScopeContext";
import { InfinitusEnginesPanel } from "../components/settings/infinitus/InfinitusEnginesPanel";

const ignoreScopeChange = () => undefined;

function SettingsEnginesRoute() {
  const { environmentId } = Route.useSearch();
  const environment = useEnvironment(environmentId ?? null);
  const primaryEnvironmentId = usePrimaryEnvironmentId();
  const machine = environmentId ?? primaryEnvironmentId;
  // Rows gate on the machine the panel manages, not a project scope retained from another page.
  return (
    <SettingsScopeProvider
      search={machine === null ? {} : { machine }}
      deviceOnly
      onChange={ignoreScopeChange}
    >
      <InfinitusEnginesPanel
        key={environmentId ?? "primary"}
        {...(environmentId ? { environment } : {})}
      />
    </SettingsScopeProvider>
  );
}

export const Route = createFileRoute("/_chat/settings/engines")({
  validateSearch: (raw: Record<string, unknown>): { environmentId?: EnvironmentId } =>
    typeof raw.environmentId === "string" && raw.environmentId.trim()
      ? { environmentId: EnvironmentId.make(raw.environmentId) }
      : {},
  component: SettingsEnginesRoute,
});
