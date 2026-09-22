/**
 * Settings › Engines (#1177): the two proxy engines' base URL and
 * secret, the form the Mac's engine panes drew. The secret is a password
 * field, autocomplete off, cleared the moment it is submitted and gone with
 * the component; it travels once, as a `Redacted` value over
 * `infinitus.secret`, and is never interpolated into any message. Saving
 * relaunches the app (`proxy-key` / `9router-password` are restart verbs),
 * so the prefs panel around this form goes quiet until the Mac answers again
 * and this form re-reads then.
 *
 * @module InfinitusEngineSecrets
 */
import * as Cause from "effect/Cause";
import * as Redacted from "effect/Redacted";
import { useCallback, useEffect, useState } from "react";

import type { EnvironmentPresentation } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../../ui/select";
import { Switch } from "../../ui/switch";
import { SettingsRow, SettingsSection } from "../settingsLayout";
import {
  affinityInput,
  affinitySupported,
  connectionTestInput,
  connectionTestLine,
  engineSecretInput,
  engineSecretsSupported,
  parseConnectionTest,
  parseProxyEngineState,
  PROXY_ENGINES,
  ROUTING_STRATEGIES,
  routingInput,
  routingNotes,
  routingSupported,
  testConnectionSupported,
  type ProxyEngine,
  type ProxyEngineKey,
  type ProxyEngineState,
} from "./engines.logic";
import {
  InfinitusEngineProcessRows,
  type InfinitusEngineProcesses,
} from "./InfinitusEngineControls";
import { InfinitusPanelNotice, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { infinitusCommandFailure } from "./panel.logic";
import { isAuthorizationFailure } from "./pairingAccess.logic";

const UNSUPPORTED = "This Infinitus build has no engine secret commands (needs ≥ 4eaccb341c).";
const FORBIDDEN = "Only the desktop app on this Mac can change engine secrets.";
const RELAUNCHING = "Saved. Infinitus is relaunching — this page picks up again when it answers.";
const TEST_UNAVAILABLE = "Test connection needs a newer Infinitus app.";

type PerEngine<T> = Partial<Record<ProxyEngineKey, T>>;

export function InfinitusEngineSecrets({
  environment,
  processes = null,
}: {
  readonly environment?: EnvironmentPresentation | null;
  /** This computer's engine processes, drawn at the foot of each engine's
      section; `null` for a remote environment or outside the desktop shell. */
  readonly processes?: InfinitusEngineProcesses | null;
}) {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment(environment);
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const [states, setStates] = useState<PerEngine<ProxyEngineState>>({});
  const [errors, setErrors] = useState<PerEngine<string>>({});
  /** The url field, seeded from the read once and the user's from then on. */
  const [urls, setUrls] = useState<PerEngine<string>>({});
  const [secrets, setSecrets] = useState<PerEngine<string>>({});
  const [busy, setBusy] = useState<ProxyEngineKey | null>(null);
  const [relaunching, setRelaunching] = useState(false);
  /** The last probe's line per engine; cleared when the url changes. */
  const [probes, setProbes] = useState<PerEngine<string>>({});

  const supported =
    snapshot !== null && snapshot.available && engineSecretsSupported(snapshot.commands);
  const probeSupported =
    snapshot !== null && snapshot.available && testConnectionSupported(snapshot.commands);
  const routingOn = snapshot !== null && snapshot.available && routingSupported(snapshot.commands);
  const affinityOn =
    snapshot !== null && snapshot.available && affinitySupported(snapshot.commands);

  const read = useCallback(
    async (engine: ProxyEngine) => {
      if (environmentId === null) return;
      const result = await runCommand({
        environmentId,
        input: { command: engine.readVerb, args: [], options: {} },
      });
      if (result._tag === "Failure") {
        setErrors((current) => ({
          ...current,
          [engine.key]: infinitusCommandFailure(result.cause).message,
        }));
        return;
      }
      const parsed = parseProxyEngineState(result.value.result);
      if (parsed === null) {
        setErrors((current) => ({
          ...current,
          [engine.key]: `Infinitus answered ${engine.readVerb} with a shape this build cannot read.`,
        }));
        return;
      }
      setErrors((current) => ({ ...current, [engine.key]: undefined }));
      setStates((current) => ({ ...current, [engine.key]: parsed }));
      setUrls((current) =>
        current[engine.key] === undefined ? { ...current, [engine.key]: parsed.baseURL } : current,
      );
      setRelaunching(false);
    },
    [environmentId, runCommand],
  );

  // The engines' settings are not part of the snapshot: read once the app
  // answers, and again after a save's relaunch brings it back.
  useEffect(() => {
    if (!supported) return;
    for (const engine of PROXY_ENGINES) void read(engine);
  }, [read, supported]);

  const write = useCallback(
    async (engine: ProxyEngine, value: string) => {
      if (environmentId === null) return;
      // Cleared before the call: the field never outlives the submit.
      setSecrets((current) => ({ ...current, [engine.key]: "" }));
      setBusy(engine.key);
      const result = await runSecret({
        environmentId,
        input: {
          ...engineSecretInput(engine.key, urls[engine.key] ?? ""),
          secret: Redacted.make(value),
        },
      });
      setBusy(null);
      if (result._tag === "Failure") {
        const error = result.cause;
        setErrors((current) => ({
          ...current,
          [engine.key]: isAuthorizationFailure(Cause.squash(error))
            ? FORBIDDEN
            : infinitusCommandFailure(error).message,
        }));
        return;
      }
      setErrors((current) => ({ ...current, [engine.key]: undefined }));
      setRelaunching(true);
    },
    [environmentId, runSecret, urls],
  );

  // The probe reads the typed url and never saves it: the Mac reaches the
  // engine with the credential in its keychain and answers with the round
  // trip or the engine's own words, which are shown as they are.
  const probe = useCallback(
    async (engine: ProxyEngine) => {
      if (environmentId === null) return;
      setBusy(engine.key);
      const result = await runCommand({
        environmentId,
        input: connectionTestInput(engine.key, urls[engine.key] ?? ""),
      });
      setBusy(null);
      const line =
        result._tag === "Failure"
          ? infinitusCommandFailure(result.cause).message
          : (() => {
              const parsed = parseConnectionTest(result.value.result);
              return parsed === null
                ? "Infinitus answered test-connection with a shape this build cannot read."
                : connectionTestLine(parsed);
            })();
      setProbes((current) => ({ ...current, [engine.key]: line }));
    },
    [environmentId, runCommand, urls],
  );

  // The routing knobs (#1235) are plain writes over `infinitus.command`; the
  // engine's settings are not in the snapshot, so the proxy is read again
  // after each one and the select or switch follows what it answers.
  const route = useCallback(
    async (engine: ProxyEngine, input: ReturnType<typeof routingInput>) => {
      if (environmentId === null) return;
      setBusy(engine.key);
      const result = await runCommand({ environmentId, input });
      setBusy(null);
      if (result._tag === "Failure") {
        setErrors((current) => ({
          ...current,
          [engine.key]: infinitusCommandFailure(result.cause).message,
        }));
        return;
      }
      await read(engine);
    },
    [environmentId, read, runCommand],
  );

  const answering = capability === true && snapshot !== null && snapshot.available;
  // The shell runs the engines whether or not the app answers, so their rows
  // stay when the connection rows cannot be drawn.
  if (!answering || !supported) {
    return (
      <>
        {answering ? (
          <SettingsSection id="infinitus-engine-secrets" title="Proxy engines">
            <InfinitusPanelNotice message={UNSUPPORTED} />
          </SettingsSection>
        ) : null}
        {processes === null
          ? null
          : PROXY_ENGINES.map((engine) => (
              <SettingsSection
                key={engine.key}
                id={`infinitus-engine-${engine.key}`}
                title={engine.label}
              >
                <InfinitusEngineProcessRows
                  processes={processes}
                  engineKey={engine.key}
                  label={engine.label}
                />
              </SettingsSection>
            ))}
      </>
    );
  }

  return (
    <>
      {PROXY_ENGINES.map((engine) => {
        const state = states[engine.key];
        const error = errors[engine.key];
        const secret = secrets[engine.key] ?? "";
        const locked = busy !== null || relaunching || state === undefined;
        return (
          <SettingsSection
            key={engine.key}
            id={`infinitus-engine-${engine.key}`}
            title={engine.label}
          >
            <SettingsRow
              serverScoped
              title="Base URL"
              description={`Stored with the ${engine.secretNoun.toLowerCase()} on save. Blank means ${engine.defaultUrl}.`}
              control={
                <Input
                  size="sm"
                  aria-label={`${engine.label} base URL`}
                  placeholder={engine.defaultUrl}
                  spellCheck={false}
                  disabled={locked}
                  value={urls[engine.key] ?? ""}
                  onChange={(event) => {
                    setUrls((current) => ({ ...current, [engine.key]: event.target.value }));
                    setProbes((current) => ({ ...current, [engine.key]: undefined }));
                  }}
                />
              }
            />
            <SettingsRow
              serverScoped
              title={engine.secretLabel}
              description={`${engine.secretNoun} ${state?.secretPresent === true ? "set." : "not set."} Saving relaunches Infinitus.`}
              control={
                <div className="flex flex-wrap items-center gap-2">
                  <Input
                    size="sm"
                    type="password"
                    autoComplete="off"
                    spellCheck={false}
                    aria-label={`${engine.label} ${engine.secretLabel.toLowerCase()}`}
                    placeholder={state?.secretPresent === true ? "Replace" : "Paste"}
                    disabled={locked}
                    value={secret}
                    onChange={(event) =>
                      setSecrets((current) => ({ ...current, [engine.key]: event.target.value }))
                    }
                  />
                  <Button
                    size="sm"
                    variant="outline"
                    aria-label={`Save ${engine.label} and relaunch`}
                    disabled={locked || secret === ""}
                    onClick={() => void write(engine, secret)}
                  >
                    Save and relaunch
                  </Button>
                  {state?.secretPresent === true ? (
                    <Button
                      size="sm"
                      variant="ghost"
                      aria-label={`Forget ${engine.label} ${engine.secretNoun.toLowerCase()}`}
                      disabled={locked}
                      onClick={() => void write(engine, "")}
                    >
                      Forget {engine.secretNoun.toLowerCase()}
                    </Button>
                  ) : null}
                </div>
              }
            />
            <SettingsRow
              title="Connection"
              description={
                probeSupported
                  ? `Reaches ${engine.label} at the URL above with the stored ${engine.secretNoun.toLowerCase()}; nothing is saved.`
                  : TEST_UNAVAILABLE
              }
              control={
                <Button
                  size="sm"
                  variant="outline"
                  aria-label={`Test ${engine.label} connection`}
                  disabled={!probeSupported || locked}
                  onClick={() => void probe(engine)}
                >
                  Test connection
                </Button>
              }
            />
            {engine.key === "cliproxy" && routingOn ? (
              <ProxyRoutingRows
                engine={engine}
                state={state}
                locked={locked}
                affinityOn={affinityOn}
                onStrategy={(strategy) => void route(engine, routingInput(strategy))}
                onAffinity={(on) => void route(engine, affinityInput(on))}
              />
            ) : null}
            {state?.dashboardURL ? (
              <SettingsRow
                title="Dashboard"
                description={engine.dashboardNote}
                control={
                  <a
                    href={state.dashboardURL}
                    target="_blank"
                    rel="noreferrer"
                    className="text-sm underline underline-offset-4"
                  >
                    {`Open ${engine.label} dashboard`}
                  </a>
                }
              />
            ) : null}
            {processes === null ? null : (
              <InfinitusEngineProcessRows
                processes={processes}
                engineKey={engine.key}
                label={engine.label}
              />
            )}
            {probes[engine.key] === undefined ? null : (
              <p role="status" className="px-3 py-2 text-[13px] text-muted-foreground sm:px-4">
                {probes[engine.key]}
              </p>
            )}
            {state?.error ? (
              <p className="px-3 py-2 text-[13px] text-muted-foreground sm:px-4">
                Last error from the engine: {state.error}
              </p>
            ) : null}
            {error === undefined ? null : (
              <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
                {error}
              </p>
            )}
          </SettingsSection>
        );
      })}
      {relaunching ? (
        <p className="px-3 py-2 text-[13px] text-muted-foreground sm:px-4">{RELAUNCHING}</p>
      ) : null}
    </>
  );
}

/** CLIProxyAPI's routing strategy and session affinity (#1235), the Mac's
    Routing section: the select is off until the proxy answered a strategy,
    the switch is drawn only with the verb and only when the proxy has the
    route (`sessionAffinity` present) — without it the note names the YAML. */
function ProxyRoutingRows({
  engine,
  state,
  locked,
  affinityOn,
  onStrategy,
  onAffinity,
}: {
  readonly engine: ProxyEngine;
  readonly state: ProxyEngineState | undefined;
  readonly locked: boolean;
  readonly affinityOn: boolean;
  readonly onStrategy: (strategy: string) => void;
  readonly onAffinity: (on: boolean) => void;
}) {
  const strategy = state?.routingStrategy ?? null;
  const affinity = state?.sessionAffinity ?? null;
  const notes = routingNotes(strategy, affinity);
  return (
    <>
      <SettingsRow
        serverScoped
        title="Routing strategy"
        description={notes.explainer}
        control={
          <Select
            disabled={locked || strategy === null}
            value={strategy ?? ""}
            onValueChange={(value) => {
              if (value !== null && value !== strategy) onStrategy(value);
            }}
          >
            <SelectTrigger
              size="sm"
              className="w-full sm:w-56"
              aria-label={`${engine.label} routing strategy`}
            >
              <SelectValue>
                {ROUTING_STRATEGIES.find((option) => option.value === strategy)?.label ??
                  strategy ??
                  "Not read yet"}
              </SelectValue>
            </SelectTrigger>
            <SelectPopup align="end" alignItemWithTrigger={false}>
              {ROUTING_STRATEGIES.map((option) => (
                <SelectItem hideIndicator key={option.value} value={option.value}>
                  {option.label}
                </SelectItem>
              ))}
            </SelectPopup>
          </Select>
        }
      />
      {affinityOn && affinity !== null ? (
        <SettingsRow
          serverScoped
          title="Session affinity"
          description="A conversation stays on the credential it started on."
          control={
            <Switch
              disabled={locked}
              checked={affinity}
              aria-label={`${engine.label} session affinity`}
              onCheckedChange={(checked) => onAffinity(checked === true)}
            />
          }
        />
      ) : null}
      {notes.note === null ? null : (
        <p
          className={`px-3 py-2 text-[13px] sm:px-4 ${notes.note.tone === "warn" ? "text-warning-foreground" : "text-muted-foreground"}`}
        >
          {notes.note.text}
        </p>
      )}
      {state?.caveat ? (
        <p className="px-3 py-2 text-[13px] text-muted-foreground sm:px-4">{state.caveat}</p>
      ) : null}
    </>
  );
}
