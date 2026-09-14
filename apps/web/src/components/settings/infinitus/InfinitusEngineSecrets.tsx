/**
 * Settings › Infinitus › Engines (#1177): the two proxy engines' base URL and
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
import { SettingsRow, SettingsSection } from "../settingsLayout";
import {
  connectionTestInput,
  connectionTestLine,
  engineSecretInput,
  engineSecretsSupported,
  parseConnectionTest,
  parseProxyEngineState,
  PROXY_ENGINES,
  testConnectionSupported,
  type ProxyEngine,
  type ProxyEngineKey,
  type ProxyEngineState,
} from "./engines.logic";
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
}: {
  readonly environment?: EnvironmentPresentation | null;
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

  if (capability !== true || snapshot === null || !snapshot.available) return null;
  if (!supported) {
    return (
      <SettingsSection id="infinitus-engine-secrets" title="Proxy engines">
        <InfinitusPanelNotice message={UNSUPPORTED} />
      </SettingsSection>
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
