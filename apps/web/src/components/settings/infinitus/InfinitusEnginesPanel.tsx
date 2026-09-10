/**
 * The Engines pane: what each engine is doing right now, above the toggles
 * that turn them on. Keys stay on the Mac — the fork never shows or writes
 * one, it only says whether the app has it and hands the user over.
 *
 * @module InfinitusEnginesPanel
 */
import { Badge } from "../../ui/badge";
import { Button } from "../../ui/button";
import { SettingsRow, SettingsSection } from "../settingsLayout";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { buildEngineStatusRows } from "./panel.logic";
import { InfinitusPrefsPanel, useInfinitusEnvironment } from "./InfinitusPrefsPanel";

const KEY_STATUS: Readonly<Record<"present" | "missing", string>> = {
  present: "Key set",
  missing: "No key",
};

function InfinitusEngineStatusList() {
  const { environmentId, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
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
          control={
            row.keyState === "none" ? null : (
              // The key itself is entered in the Mac app's own Settings; it
              // never crosses this boundary.
              <Button
                size="sm"
                variant="outline"
                disabled={environmentId === null}
                onClick={() => {
                  if (environmentId === null) return;
                  void runCommand({
                    environmentId,
                    input: { command: "show", args: ["settings"], options: {} },
                  });
                }}
              >
                Manage in Infinitus
              </Button>
            )
          }
        />
      ))}
    </SettingsSection>
  );
}

export function InfinitusEnginesPanel() {
  return (
    <InfinitusPrefsPanel sectionSlugs={["engines"]} title="Engines">
      <InfinitusEngineStatusList />
    </InfinitusPrefsPanel>
  );
}
