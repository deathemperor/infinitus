/**
 * The Engines pane: what each engine is doing right now, the toggles that
 * turn them on, and the proxy engines' base URL and secret (#1177,
 * `InfinitusEngineSecrets`) — the form the Mac's own engine panes drew. A key
 * travels once, over `infinitus.secret`; the status list only says whether
 * the app has one.
 *
 * @module InfinitusEnginesPanel
 */
import type { EnvironmentPresentation } from "~/state/environments";
import { Badge } from "../../ui/badge";
import { SettingsRow, SettingsSection } from "../settingsLayout";

import { InfinitusEngineSecrets } from "./InfinitusEngineSecrets";
import { InfinitusPrefsPanel, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { buildEngineStatusRows } from "./panel.logic";

const KEY_STATUS: Readonly<Record<"present" | "missing", string>> = {
  present: "Key set",
  missing: "No key",
};

function InfinitusEngineStatusList({
  environment,
}: {
  readonly environment?: EnvironmentPresentation | null;
}) {
  const { snapshot } = useInfinitusEnvironment(environment);
  const rows = buildEngineStatusRows(snapshot?.status);
  if (rows.length === 0) return null;

  return (
    <SettingsSection id="infinitus-engine-status" title="Engine status">
      {rows.map((row) => (
        <SettingsRow
          key={row.key}
          title={row.label}
          status={
            <span className="flex flex-wrap items-center gap-1.5">
              <Badge variant={row.enabled ? "default" : "outline"}>
                {row.enabled ? "On" : "Off"}
              </Badge>
              <Badge variant="outline">{row.registered ? "Registered" : "Not registered"}</Badge>
              {row.keyState === "none" ? null : (
                <Badge variant="outline">{KEY_STATUS[row.keyState]}</Badge>
              )}
            </span>
          }
        />
      ))}
    </SettingsSection>
  );
}

export function InfinitusEnginesPanel({
  environment,
}: {
  readonly environment?: EnvironmentPresentation | null;
}) {
  const target = environment === undefined ? {} : { environment };
  return (
    <InfinitusPrefsPanel {...target} sectionSlugs={["engines"]} title="Engines">
      {environment ? (
        <p className="px-3 text-sm sm:px-4">Managing engines on {environment.label}.</p>
      ) : null}
      <p className="px-3 text-sm text-muted-foreground sm:px-4">
        Engines manage your provider accounts and switching.{" "}
        <a
          href="https://github.com/deathemperor/infinitus/blob/main/docs/user/accounts.md"
          target="_blank"
          rel="noreferrer"
          className="underline underline-offset-4"
        >
          Read the accounts setup guide
        </a>
      </p>
      <InfinitusEngineStatusList {...target} />
      <InfinitusEngineSecrets {...target} />
    </InfinitusPrefsPanel>
  );
}
