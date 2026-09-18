/**
 * The Engines pane: what each engine is doing right now, the toggles that
 * turn them on, and the proxy engines' base URL and secret (#1177,
 * `InfinitusEngineSecrets`) — the form the Mac's own engine panes drew. A key
 * travels once, over `infinitus.secret`; the status list only says whether
 * the app has one.
 *
 * @module InfinitusEnginesPanel
 */
import { Link } from "@tanstack/react-router";

import type { EnvironmentPresentation } from "~/state/environments";
import { Badge } from "../../ui/badge";
import { Button } from "../../ui/button";
import { SettingsRow, SettingsSection } from "../settingsLayout";

import { InfinitusEngineControls } from "./InfinitusEngineControls";
import { InfinitusEngineSecrets } from "./InfinitusEngineSecrets";
import { InfinitusPrefsPanel, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { buildEngineStatusRows, menuBarAppVersionLine } from "./panel.logic";

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
  // The Activity sub screen reads the primary environment's log, so the way
  // in is drawn only when this page manages that environment.
  const activityLink = environment ? null : (
    <Button render={<Link to="/settings/infinitus/engines/activity" />} size="sm" variant="outline">
      View activity
    </Button>
  );

  return (
    <SettingsSection id="infinitus-engine-status" title="Engine status">
      {rows.map((row) => (
        <SettingsRow
          key={row.key}
          title={row.label}
          description={row.detail ?? undefined}
          control={row.key === "swapd" ? activityLink : undefined}
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
      {rows
        .filter((row) => row.error !== null)
        .map((row) => (
          <p key={row.key} className="px-3 py-2 text-[13px] text-destructive sm:px-4">
            {row.label}: {row.error}
          </p>
        ))}
    </SettingsSection>
  );
}

/** About, the Mac's pane folded into this page (2026-09-14): version and
    build only. The menu bar app is bundled with the desktop app and updates
    with it, so there is nothing to check for or switch here. */
function InfinitusAboutSection({
  environment,
}: {
  readonly environment?: EnvironmentPresentation | null;
}) {
  const { snapshot } = useInfinitusEnvironment(environment);
  const line = menuBarAppVersionLine(snapshot?.status);
  if (line === undefined) return null;

  return (
    <SettingsSection id="infinitus-about" title="About">
      <SettingsRow
        title={line}
        description="Bundled with the desktop app; updates arrive with it."
        control={
          <a
            href="https://github.com/deathemperor/infinitus/releases"
            target="_blank"
            rel="noreferrer"
            className="text-sm underline underline-offset-4"
          >
            Releases
          </a>
        }
      />
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
      {/* This computer's own engine processes, so never for a named remote
          environment: the shell can only start one on the machine it runs on. */}
      {environment ? null : <InfinitusEngineControls />}
      <InfinitusAboutSection {...target} />
    </InfinitusPrefsPanel>
  );
}
