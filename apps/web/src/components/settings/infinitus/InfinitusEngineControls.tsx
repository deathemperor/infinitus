/**
 * Start and stop the proxy engines from the Engines page.
 *
 * A thread on a proxied Claude instance dies with `ConnectionRefused` when its
 * engine is down, and the page could only report it. The desktop shell runs the
 * engine instead — it is the app on the machine the engine runs on, and unlike
 * the menu-bar app it is the one the user is already looking at.
 *
 * Shown only in the desktop shell, and only for this computer: the buttons act
 * on the machine running this window, never on a named remote environment.
 *
 * @module InfinitusEngineControls
 */
import type { InfinitusEngineSupervision, InfinitusEngines } from "@infinitus/contracts/infinitus";
import { useCallback, useEffect, useMemo, useState } from "react";

import { Badge } from "../../ui/badge";
import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
import { Switch } from "../../ui/switch";
import { SettingsRow, SettingsSection } from "../settingsLayout";
import { PROXY_ENGINES } from "./engines.logic";
import {
  engineBadge,
  engineControlsEnabled,
  engineIsUp,
  engineStateLine,
  infinitusEngineBridge,
} from "./engineControls.logic";

const BADGE_VARIANT = {
  up: "default",
  warn: "secondary",
  down: "outline",
} as const;

export function InfinitusEngineControls() {
  // A window global, fixed for the page's life.
  const bridge = useMemo(
    () => infinitusEngineBridge(typeof window === "undefined" ? undefined : window.desktopBridge),
    [],
  );
  const [engines, setEngines] = useState<InfinitusEngines | null>(null);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const apply = useCallback((next: InfinitusEngines) => {
    setEngines(next);
    // A command the user has not touched follows what the shell resolved.
    setDrafts((current) => {
      const merged = { ...current };
      for (const engine of next.engines) {
        if (merged[engine.key] === undefined) merged[engine.key] = engine.command ?? "";
      }
      return merged;
    });
  }, []);

  useEffect(() => {
    if (bridge === null) return;
    let cancelled = false;
    bridge.getInfinitusEngines().then(
      (loaded) => {
        if (!cancelled) apply(loaded);
      },
      (cause: unknown) => {
        if (!cancelled) setError(cause instanceof Error ? cause.message : String(cause));
      },
    );
    return () => {
      cancelled = true;
    };
  }, [bridge, apply]);

  const run = useCallback(
    (key: string, change: Promise<InfinitusEngines>) => {
      setError(null);
      setBusy(key);
      change
        .then(apply, (cause: unknown) => {
          setError(cause instanceof Error ? cause.message : String(cause));
        })
        .finally(() => setBusy(null));
    },
    [apply],
  );

  if (bridge === null || engines === null) return null;

  return (
    <SettingsSection id="infinitus-engine-processes" title="On this computer">
      <p className="px-3 text-sm text-muted-foreground sm:px-4">
        Engines this window runs. A managed engine starts with the app, is restarted if it stops,
        and shuts down when the app quits.
      </p>
      {engines.engines.map((engine) => {
        const definition = PROXY_ENGINES.find((entry) => entry.key === engine.key);
        const label = definition?.label ?? engine.key;
        const badge = engineBadge(engine);
        const controllable = engineControlsEnabled(engine);
        const locked = busy !== null;
        const draft = drafts[engine.key] ?? "";
        const commandChanged = draft.trim() !== (engine.command ?? "").trim();
        return (
          <EngineRows
            key={engine.key}
            engine={engine}
            label={label}
            badge={badge}
            controllable={controllable}
            locked={locked}
            draft={draft}
            commandChanged={commandChanged}
            onDraft={(value) => setDrafts((current) => ({ ...current, [engine.key]: value }))}
            onManaged={(managed) =>
              run(engine.key, bridge.setInfinitusEngineSettings({ key: engine.key, managed }))
            }
            onSaveCommand={() =>
              run(
                engine.key,
                bridge.setInfinitusEngineSettings({ key: engine.key, command: draft }),
              )
            }
            onAction={(action) =>
              run(engine.key, bridge.controlInfinitusEngine({ key: engine.key, action }))
            }
          />
        );
      })}
      {error === null ? null : (
        <p className="px-3 py-2 text-[13px] text-destructive sm:px-4">{error}</p>
      )}
    </SettingsSection>
  );
}

function EngineRows({
  engine,
  label,
  badge,
  controllable,
  locked,
  draft,
  commandChanged,
  onDraft,
  onManaged,
  onSaveCommand,
  onAction,
}: {
  readonly engine: InfinitusEngineSupervision;
  readonly label: string;
  readonly badge: ReturnType<typeof engineBadge>;
  readonly controllable: boolean;
  readonly locked: boolean;
  readonly draft: string;
  readonly commandChanged: boolean;
  readonly onDraft: (value: string) => void;
  readonly onManaged: (managed: boolean) => void;
  readonly onSaveCommand: () => void;
  readonly onAction: (action: "start" | "stop" | "restart") => void;
}) {
  const up = engineIsUp(engine);
  return (
    <>
      <SettingsRow
        title={label}
        description={engineStateLine(engine)}
        status={<Badge variant={BADGE_VARIANT[badge.tone]}>{badge.label}</Badge>}
        control={
          <div className="flex flex-wrap items-center gap-2">
            <Button
              size="sm"
              variant="outline"
              aria-label={up ? `Restart ${label}` : `Start ${label}`}
              disabled={!controllable || locked}
              onClick={() => onAction(up ? "restart" : "start")}
            >
              {up ? "Restart" : "Start"}
            </Button>
            <Button
              size="sm"
              variant="outline"
              aria-label={`Stop ${label}`}
              disabled={!controllable || locked || !up}
              onClick={() => onAction("stop")}
            >
              Stop
            </Button>
          </div>
        }
      />
      <SettingsRow
        title="Keep it running"
        description="Start this engine with the app and restart it if it stops."
        control={
          <Switch
            aria-label={`Keep ${label} running`}
            disabled={!controllable || locked}
            checked={engine.managed}
            onCheckedChange={(checked) => onManaged(checked === true)}
          />
        }
      />
      <SettingsRow
        title="Command"
        description={
          engine.detectedCommand === null
            ? "This app has no PATH of its own, so give the program's full path."
            : `Blank uses what was found: ${engine.detectedCommand}`
        }
        control={
          <div className="flex flex-wrap items-center gap-2">
            <Input
              size="sm"
              spellCheck={false}
              aria-label={`${label} command`}
              placeholder={engine.detectedCommand ?? "/full/path/to/the/engine"}
              disabled={locked}
              value={draft}
              onChange={(event) => onDraft(event.target.value)}
            />
            <Button
              size="sm"
              variant="outline"
              aria-label={`Save the ${label} command`}
              disabled={locked || !commandChanged}
              onClick={onSaveCommand}
            >
              Save
            </Button>
          </div>
        }
      />
    </>
  );
}
