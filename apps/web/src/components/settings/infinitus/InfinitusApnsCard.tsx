/**
 * Settings › Infinitus › Devices › Phone alerts (#1178): the APNs `.p8` key
 * and the phones registered for pushes, under the prefs panel's Team ID and
 * Key ID rows. The key is a file input, never a text field: the file is read
 * in the browser, checked for the PEM header, handed once to
 * `infinitus.secret` as `apns-key` (a `Redacted` value) and kept nowhere —
 * not in state, not in a message, not in a log. "Forget key" is the same verb
 * with an empty secret. The read (`apns`) never carries a token.
 *
 * @module InfinitusApnsCard
 */
import * as Cause from "effect/Cause";
import * as Redacted from "effect/Redacted";
import { useCallback, useEffect, useState } from "react";

import { usePrimarySettings } from "~/hooks/useSettings";
import type { EnvironmentPresentation } from "~/state/environments";
import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";
import { formatDayAwareTimestamp } from "~/timestampFormat";

import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
import { SettingsRow, SettingsSection } from "../settingsLayout";
import {
  apnsKeyIdFromPrefs,
  apnsSupported,
  isPemPrivateKey,
  parseApnsStatus,
  lastPushLine,
  registrationLine,
  type ApnsStatus,
} from "./apns.logic";
import { InfinitusPanelNotice, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { infinitusCommandFailure } from "./panel.logic";
import { isAuthorizationFailure } from "./pairingAccess.logic";

const UNSUPPORTED = "This Infinitus build has no push key commands (needs ≥ c3c4dae7aa).";
const FORBIDDEN = "Only the desktop app on this Mac can change the push key.";
const NOT_PEM = "That is not a .p8 key (expected -----BEGIN PRIVATE KEY-----). Nothing was sent.";
const NEEDS_KEY_ID = "Set the Key ID above first; the key is stored under it.";
const HOW_TO =
  "Upload the .p8 from your developer account (Certificates, Identifiers & Profiles → Keys → Apple Push Notifications service). It stays in this Mac's keychain and is never shown again.";

export function InfinitusApnsCard({
  environment,
}: {
  readonly environment?: EnvironmentPresentation | null;
}) {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment(environment);
  const timestampFormat = usePrimarySettings((settings) => settings.timestampFormat);
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const [status, setStatus] = useState<ApnsStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const supported = snapshot !== null && snapshot.available && apnsSupported(snapshot.commands);
  const keyId = apnsKeyIdFromPrefs(snapshot?.prefs);

  const read = useCallback(async () => {
    if (environmentId === null) return;
    const result = await runCommand({
      environmentId,
      input: { command: "apns", args: [], options: {} },
    });
    if (result._tag === "Failure") {
      setError(infinitusCommandFailure(result.cause).message);
      return;
    }
    const parsed = parseApnsStatus(result.value.result);
    if (parsed === null) {
      setError("Infinitus answered apns with a shape this build cannot read.");
      return;
    }
    setError(null);
    setStatus(parsed);
  }, [environmentId, runCommand]);

  // The push setup is not part of the snapshot: read once the app answers.
  useEffect(() => {
    if (!supported) return;
    void read();
  }, [read, supported]);

  const write = useCallback(
    async (pem: string) => {
      if (environmentId === null) return;
      setBusy(true);
      const result = await runSecret({
        environmentId,
        input: { command: "apns-key", args: {}, secret: Redacted.make(pem) },
      });
      setBusy(false);
      if (result._tag === "Failure") {
        setError(
          isAuthorizationFailure(Cause.squash(result.cause))
            ? FORBIDDEN
            : infinitusCommandFailure(result.cause).message,
        );
        return;
      }
      setError(null);
      await read();
    },
    [environmentId, read, runSecret],
  );

  const pick = useCallback(
    async (event: {
      target: { files: ArrayLike<{ text: () => Promise<string> }> | null; value: string };
    }) => {
      const file = event.target.files?.[0];
      // The chooser forgets the file either way: a second pick of the same
      // file must fire again, and the name never outlives the submit.
      event.target.value = "";
      if (file === undefined) return;
      const text = await file.text();
      if (!isPemPrivateKey(text)) {
        setError(NOT_PEM);
        return;
      }
      await write(text);
    },
    [write],
  );

  if (capability !== true || snapshot === null || !snapshot.available) return null;
  if (!supported) {
    return (
      <SettingsSection id="infinitus-apns" title="Phone alerts">
        <InfinitusPanelNotice message={UNSUPPORTED} />
      </SettingsSection>
    );
  }

  const locked = busy || status === null;
  const canUpload = keyId !== "";
  return (
    <SettingsSection id="infinitus-apns" title="Phone alerts">
      <SettingsRow
        serverScoped
        title="Push key (.p8)"
        description={canUpload ? HOW_TO : NEEDS_KEY_ID}
        status={<span>{status?.keyPresent === true ? "In the Keychain." : "Not set up."}</span>}
        control={
          <div className="flex flex-wrap items-center gap-2">
            <Input
              size="sm"
              type="file"
              accept=".p8,application/x-pem-file,application/pkcs8"
              aria-label="APNs key file"
              disabled={locked || !canUpload}
              onChange={(event) => void pick(event)}
            />
            {status?.keyPresent === true ? (
              <Button
                size="sm"
                variant="ghost"
                aria-label="Forget APNs key"
                disabled={locked}
                onClick={() => void write("")}
              >
                Forget key
              </Button>
            ) : null}
          </div>
        }
      />
      <div className="px-3 py-2 text-[13px] sm:px-4">
        <p className="text-foreground">Registered phones</p>
        {status === null ? null : status.registrations.length === 0 ? (
          <p className="text-muted-foreground">No phones registered.</p>
        ) : (
          <ul className="text-muted-foreground">
            {status.registrations.map((row) => (
              <li key={`${row.deviceId}/${row.kind}`}>
                {registrationLine(row)} ·{" "}
                {formatDayAwareTimestamp(row.registeredAt, timestampFormat)}
                {row.lastPush === undefined
                  ? null
                  : ` · ${lastPushLine(row.lastPush, formatDayAwareTimestamp(row.lastPush.at, timestampFormat))}`}
              </li>
            ))}
          </ul>
        )}
      </div>
      {error === null ? null : (
        <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
          {error}
        </p>
      )}
    </SettingsSection>
  );
}
