/**
 * Settings › Infinitus › Profiles: the saved ways to start a session, read and
 * written over the control socket's `profiles` / `profile-set` /
 * `profile-remove`. Every field is a text box — the shape carries seven of them
 * and the Mac's own Settings › Profiles is where engines and permission modes
 * are picked from a list.
 *
 * @module InfinitusProfilesPanel
 */
import type { InfinitusProfile } from "@t3tools/contracts/infinitus";
import { useCallback, useEffect, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
import { SettingsPageContainer, SettingsRow, SettingsSection } from "../settingsLayout";
import { infinitusCommandFailure, infinitusPanelMessage } from "./panel.logic";
import { InfinitusPanelNotice, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import {
  EMPTY_PROFILE_DRAFT,
  parseInfinitusProfiles,
  profileCommandsSupported,
  profileDraft,
  profileRemoveArgs,
  profileSetArgs,
  profileSummary,
  type ProfileDraft,
} from "./profiles.logic";

const FIELDS: ReadonlyArray<{ key: keyof ProfileDraft; label: string; placeholder: string }> = [
  { key: "name", label: "Name", placeholder: "review" },
  { key: "cwd", label: "Folder", placeholder: "~/code/app" },
  { key: "engine", label: "Engine", placeholder: "claude or codex" },
  { key: "permissionMode", label: "Permission mode", placeholder: "acceptEdits" },
  { key: "model", label: "Model", placeholder: "opus" },
  { key: "systemPrompt", label: "Appended system prompt", placeholder: "" },
  { key: "prompt", label: "First prompt", placeholder: "" },
  { key: "allowTools", label: "Tools allowed without asking", placeholder: "Edit, Bash git" },
];

export function InfinitusProfilesPanel() {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [profiles, setProfiles] = useState<ReadonlyArray<InfinitusProfile> | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState<ProfileDraft | null>(null);
  const [busy, setBusy] = useState(false);

  const supported =
    snapshot !== null && snapshot.available && profileCommandsSupported(snapshot.commands);

  const load = useCallback(async () => {
    if (environmentId === null) return;
    const result = await runCommand({
      environmentId,
      input: { command: "profiles", args: [], options: {} },
    });
    if (result._tag === "Failure") {
      setError(infinitusCommandFailure(result.cause).message);
      return;
    }
    const parsed = parseInfinitusProfiles(result.value.result);
    if (parsed === null) {
      setError("Infinitus answered `profiles` with a shape this build cannot read.");
      return;
    }
    setError(null);
    setProfiles(parsed);
  }, [environmentId, runCommand]);

  // The catalog is not part of the snapshot, so it is asked for once the app is
  // answering and again after every write.
  useEffect(() => {
    if (!supported) return;
    void load();
  }, [load, supported]);

  const write = useCallback(
    async (input: {
      command: string;
      args: ReadonlyArray<string>;
      options?: Record<string, string>;
    }) => {
      if (environmentId === null) return;
      setBusy(true);
      const result = await runCommand({
        environmentId,
        input: { command: input.command, args: input.args, options: input.options ?? {} },
      });
      setBusy(false);
      if (result._tag === "Failure") {
        setError(infinitusCommandFailure(result.cause).message);
        return;
      }
      setError(null);
      setDraft(null);
      await load();
    },
    [environmentId, load, runCommand],
  );

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
        <SettingsSection id="infinitus-profiles" title="Session profiles">
          <InfinitusPanelNotice
            message={infinitusPanelMessage(
              state,
              snapshot?.unavailableReason,
              "This Infinitus build has no profile commands (needs ≥ a6a18a94d).",
            )}
          />
        </SettingsSection>
      </SettingsPageContainer>
    );
  }

  return (
    <SettingsPageContainer>
      <SettingsSection
        id="infinitus-profiles"
        title="Session profiles"
        headerAction={
          <Button
            size="xs"
            variant="outline"
            disabled={busy || draft !== null}
            onClick={() => setDraft(EMPTY_PROFILE_DRAFT)}
          >
            Add profile
          </Button>
        }
      >
        {profiles === null ? (
          <InfinitusPanelNotice message="Reading the saved profiles…" />
        ) : profiles.length === 0 ? (
          <InfinitusPanelNotice message="No profiles saved yet." />
        ) : (
          profiles.map((profile) => (
            <SettingsRow
              key={profile.name}
              title={profile.name}
              description={profileSummary(profile)}
              control={
                <>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    onClick={() => setDraft(profileDraft(profile))}
                  >
                    Edit
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy}
                    aria-label={`Remove ${profile.name}`}
                    onClick={() => void write(profileRemoveArgs(profile.name))}
                  >
                    Remove
                  </Button>
                </>
              }
            />
          ))
        )}
        {error === null ? null : (
          <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
            {error}
          </p>
        )}
      </SettingsSection>
      {draft === null ? null : (
        <SettingsSection title={draft.name === "" ? "Add a profile" : `Edit “${draft.name}”`}>
          {FIELDS.map((field) => (
            <SettingsRow
              key={field.key}
              title={field.label}
              // `profile-set` replaces the profile with exactly the fields
              // given, so anything left empty here is cleared.
              description={
                field.key === "name" ? "Names an existing profile to replace it." : undefined
              }
              control={
                <Input
                  size="sm"
                  className="w-full sm:w-64"
                  aria-label={field.label}
                  placeholder={field.placeholder}
                  value={draft[field.key]}
                  onChange={(event) =>
                    setDraft({ ...draft, [field.key]: event.currentTarget.value })
                  }
                />
              }
            />
          ))}
          <SettingsRow
            title="Save"
            description="Every field left empty is cleared on the saved profile."
            control={
              <>
                <Button size="sm" variant="outline" disabled={busy} onClick={() => setDraft(null)}>
                  Cancel
                </Button>
                <Button
                  size="sm"
                  disabled={busy || draft.name.trim() === ""}
                  onClick={() => void write(profileSetArgs(draft))}
                >
                  Save profile
                </Button>
              </>
            }
          />
        </SettingsSection>
      )}
    </SettingsPageContainer>
  );
}
