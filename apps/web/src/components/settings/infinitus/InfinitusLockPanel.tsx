/**
 * Settings › Infinitus › Lock (#747): the Mac's biometric lock over the
 * control socket's `lock-status` / `lock` / `unlock`. The prompts run on the
 * Mac — turning the lock on and unlocking wait for the answer there — so the
 * pane says so while a call is in flight. The app's own error text is shown
 * verbatim; a `lock off` refused inside a team becomes a confirm that sends
 * `--yes`.
 *
 * @module InfinitusLockPanel
 */
import { useCallback, useEffect, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../../ui/select";
import { Switch } from "../../ui/switch";
import { SettingsPageContainer, SettingsRow, SettingsSection } from "../settingsLayout";
import { InfinitusPanelNotice, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import {
  lockCommandInput,
  lockCommandsSupported,
  lockOffRefusalTeams,
  parseLockStatus,
  RELOCK_CHOICES,
  relockChoiceFor,
  type LockAction,
  type LockStatus,
} from "./lock.logic";
import { infinitusCommandFailure, infinitusPanelMessage } from "./panel.logic";

const UNSUPPORTED = "This Infinitus build has no lock commands (needs ≥ 5bc33fa5c0).";

export function InfinitusLockPanel() {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [status, setStatus] = useState<LockStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** The teams a refused `lock off` named; the confirm row shows while set. */
  const [offWarning, setOffWarning] = useState<ReadonlyArray<string> | null>(null);
  /** The action waiting on the Mac, for the button labels. */
  const [busy, setBusy] = useState<LockAction["type"] | null>(null);

  const supported =
    snapshot !== null && snapshot.available && lockCommandsSupported(snapshot.commands);

  const run = useCallback(
    async (action: LockAction) => {
      if (environmentId === null) return;
      // The initial read is not a wait on the Mac; only the writes are.
      if (action.type !== "status") setBusy(action.type);
      const result = await runCommand({ environmentId, input: lockCommandInput(action) });
      setBusy(null);
      if (result._tag === "Failure") {
        const message = infinitusCommandFailure(result.cause).message;
        const teams = action.type === "off" && !action.force ? lockOffRefusalTeams(message) : null;
        if (teams !== null) {
          setOffWarning(teams);
          setError(null);
          return;
        }
        setError(message);
        return;
      }
      const parsed = parseLockStatus(result.value.result);
      if (parsed === null) {
        setError("Infinitus answered the lock command with a shape this build cannot read.");
        return;
      }
      setError(null);
      setOffWarning(null);
      setStatus(parsed);
    },
    [environmentId, runCommand],
  );

  // The lock state is not part of the snapshot, so it is asked for once the
  // app is answering; every write answers with the new state.
  useEffect(() => {
    if (!supported) return;
    void run({ type: "status" });
  }, [run, supported]);

  if (capability !== true || snapshot === null || !snapshot.available || !supported) {
    const state =
      capability !== true
        ? "unsupported"
        : snapshot === null
          ? "loading"
          : !snapshot.available
            ? "unavailable"
            : "empty";
    return (
      <SettingsPageContainer>
        <SettingsSection id="infinitus-lock" title="Unlocking">
          <InfinitusPanelNotice
            message={infinitusPanelMessage(state, snapshot?.unavailableReason, UNSUPPORTED)}
          />
        </SettingsSection>
      </SettingsPageContainer>
    );
  }

  const relock = status === null ? null : relockChoiceFor(status.relock);
  const disabled = busy !== null || status === null;

  return (
    <SettingsPageContainer>
      <SettingsSection id="infinitus-lock" title="Unlocking">
        <SettingsRow
          title="Unlock with Touch ID or password"
          description={
            busy === "on"
              ? "Confirm on the Mac — its unlock prompt is open."
              : "The Mac's pop-out and settings window show a locked state until you unlock there; biometrics fall back to the login password. Teams need this on."
          }
          control={
            <Switch
              checked={status?.enabled ?? false}
              disabled={disabled}
              aria-label="Unlock with Touch ID or password"
              onCheckedChange={(checked) =>
                void run(checked === true ? { type: "on" } : { type: "off", force: false })
              }
            />
          }
        />
        {offWarning === null ? null : (
          <SettingsRow
            title="Turn off biometric unlock?"
            description={`You're in ${offWarning.join(", ")}. Team data stays on this Mac and re-locks only behind the identity prompt on each launch; you stay in the team.`}
            control={
              <>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy !== null}
                  onClick={() => setOffWarning(null)}
                >
                  Keep on
                </Button>
                <Button
                  size="sm"
                  variant="destructive"
                  disabled={busy !== null}
                  onClick={() => void run({ type: "off", force: true })}
                >
                  Turn off
                </Button>
              </>
            }
          />
        )}
        <SettingsRow
          title="Re-lock"
          description="A timed re-lock settles on your next interaction or when the Mac wakes; nothing ticks while it is idle."
          control={
            <Select
              disabled={disabled || status?.enabled !== true}
              value={relock?.arg ?? null}
              onValueChange={(value) => {
                const choice = RELOCK_CHOICES.find((candidate) => candidate.arg === value);
                if (choice !== undefined) void run({ type: "relock", arg: choice.arg });
              }}
            >
              <SelectTrigger size="sm" className="w-full sm:w-56" aria-label="Re-lock">
                <SelectValue>{relock?.label ?? status?.relock ?? "—"}</SelectValue>
              </SelectTrigger>
              <SelectPopup align="end" alignItemWithTrigger={false}>
                {RELOCK_CHOICES.map((choice) => (
                  <SelectItem hideIndicator key={choice.arg} value={choice.arg}>
                    {choice.label}
                  </SelectItem>
                ))}
              </SelectPopup>
            </Select>
          }
        />
        <SettingsRow
          title={status?.locked === true ? "Locked" : "Unlocked"}
          description={
            busy === "unlock"
              ? "Confirm on the Mac — its unlock prompt is open."
              : status?.locked === true
                ? "The Mac shows its locked state. Unlocking runs the prompt there."
                : "Lock now hides the Mac's pop-out and settings behind the prompt."
          }
          control={
            status?.locked === true ? (
              <Button
                size="sm"
                variant="outline"
                disabled={disabled || status.enabled !== true}
                onClick={() => void run({ type: "unlock" })}
              >
                Unlock
              </Button>
            ) : (
              <Button
                size="sm"
                variant="outline"
                disabled={disabled || status?.enabled !== true}
                onClick={() => void run({ type: "now" })}
              >
                Lock now
              </Button>
            )
          }
        />
        {error === null ? null : (
          <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
            {error}
          </p>
        )}
      </SettingsSection>
    </SettingsPageContainer>
  );
}
