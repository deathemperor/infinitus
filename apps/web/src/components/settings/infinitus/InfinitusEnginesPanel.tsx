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
import { useCallback, useEffect, useState } from "react";

import type { EnvironmentPresentation } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";
import { Badge } from "../../ui/badge";
import { Button } from "../../ui/button";
import { SettingsRow, SettingsSection } from "../settingsLayout";

import { useInfinitusEngineProcesses } from "./InfinitusEngineControls";
import {
  engineUpdateCheckInput,
  engineUpdateInput,
  engineUpdateLine,
  engineUpdateSupported,
  parseEngineUpdateCheck,
} from "./engineUpdate.logic";
import { InfinitusEnginePolicy } from "./InfinitusEnginePolicy";
import { InfinitusEngineSecrets } from "./InfinitusEngineSecrets";
import { InfinitusPrefsPanel, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import {
  buildEngineStatusRows,
  infinitusCommandFailure,
  menuBarAppVersionLine,
} from "./panel.logic";

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
  const updateOn =
    snapshot !== null && snapshot.available && engineUpdateSupported(snapshot.commands);
  const swapdRegistered = rows.some((row) => row.key === "swapd" && row.registered);
  if (rows.length === 0) return null;
  // The Activity sub screen reads the primary environment's log, so the way
  // in is drawn only when this page manages that environment.
  const activityLink = environment ? null : (
    <Button render={<Link to="/settings/engines/activity" />} size="sm" variant="outline">
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
          <p key={row.key} className="px-3 py-2 text-sm text-destructive sm:px-4">
            {row.label}: {row.error}
          </p>
        ))}
      {updateOn && swapdRegistered ? (
        <InfinitusEngineUpdateRow {...(environment === undefined ? {} : { environment })} />
      ) : null}
    </SettingsSection>
  );
}

const UPDATING = "Installing. Infinitus is relaunching — this page picks up again when it answers.";

/** The engine's newest release against the one running (#1577): read once
    the row mounts, installed on the owning Mac by a restart verb, so the row
    goes quiet until the app answers again. */
function InfinitusEngineUpdateRow({
  environment,
}: {
  readonly environment?: EnvironmentPresentation | null;
}) {
  const { environmentId } = useInfinitusEnvironment(environment);
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [line, setLine] = useState<string | null>(null);
  const [updatable, setUpdatable] = useState(false);
  const [busy, setBusy] = useState(false);
  const [relaunching, setRelaunching] = useState(false);

  const check = useCallback(async () => {
    if (environmentId === null) return;
    const result = await runCommand({ environmentId, input: engineUpdateCheckInput("swapd") });
    if (result._tag === "Failure") {
      setLine(infinitusCommandFailure(result.cause).message);
      setUpdatable(false);
      return;
    }
    const parsed = parseEngineUpdateCheck(result.value.result);
    if (parsed === null) {
      setLine("Infinitus answered engine-update-check with a shape this build cannot read.");
      setUpdatable(false);
      return;
    }
    setLine(engineUpdateLine(parsed));
    setUpdatable(parsed.updatable);
  }, [environmentId, runCommand]);

  useEffect(() => {
    // oxlint-disable-next-line react/set-state-in-effect -- GitHub is asked once the row mounts; every set lands after the reply.
    void check();
  }, [check]);

  const update = useCallback(async () => {
    if (environmentId === null) return;
    setBusy(true);
    const result = await runCommand({ environmentId, input: engineUpdateInput("swapd") });
    setBusy(false);
    if (result._tag === "Failure") {
      setLine(infinitusCommandFailure(result.cause).message);
      return;
    }
    setRelaunching(true);
  }, [environmentId, runCommand]);

  return (
    <SettingsRow
      serverScoped
      title="Engine update"
      description={relaunching ? UPDATING : (line ?? "Checking the newest swapd release…")}
      control={
        <span className="flex items-center gap-1.5">
          <Button
            size="sm"
            variant="outline"
            aria-label="Check for a newer swapd release"
            disabled={busy || relaunching}
            onClick={() => void check()}
          >
            Check
          </Button>
          <Button
            size="sm"
            aria-label="Install the newest swapd release"
            disabled={!updatable || busy || relaunching}
            onClick={() => void update()}
          >
            Update
          </Button>
        </span>
      }
    />
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
  // This computer's own engine processes, so never for a named remote
  // environment: the shell can only start one on the machine it runs on.
  const localProcesses = useInfinitusEngineProcesses();
  const processes = environment ? null : localProcesses;
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
      <InfinitusEnginePolicy {...target} />
      <InfinitusEngineSecrets {...target} processes={processes} />
      <InfinitusAboutSection {...target} />
    </InfinitusPrefsPanel>
  );
}
