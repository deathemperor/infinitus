import {
  mapAtomCommandResult,
  type AtomCommandResult,
} from "@t3tools/client-runtime/state/runtime";
import {
  MAX_PROMPT_SNIPPETS_PER_PROJECT,
  MAX_PROMPT_SNIPPET_NAME_LENGTH,
  MAX_PROMPT_SNIPPET_TEXT_LENGTH,
  type EnvironmentId,
  type ProjectId,
  type PromptSnippet,
} from "@t3tools/contracts";
import { PencilIcon, PlusIcon, Trash2Icon } from "lucide-react";
import { useState } from "react";

import { useEnvironmentSettings } from "../../hooks/useSettings";
import { serverEnvironment } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { SettingsRow, SettingsSection } from "../settings/settingsLayout";
import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { Textarea } from "../ui/textarea";
import { toastManager } from "../ui/toast";
import {
  nextPromptSnippetId,
  promptSnippetDraft,
  promptSnippetPreview,
  promptSnippetsPatch,
  removePromptSnippet,
  snippetsForProject,
  upsertPromptSnippet,
} from "./promptSnippets.logic";

/** One checkout of the project group; a save writes every member. */
export interface PromptSnippetTarget {
  readonly environmentId: EnvironmentId;
  readonly projectId: ProjectId;
  /** The environment's label for the "connect and retry" toast. */
  readonly label: string;
  readonly connected: boolean;
}

/**
 * Settings › Projects › Prompts (#270 G): the project's saved snippets with
 * add, edit and remove, stored in server settings under
 * `projectPromptSnippets`. The list is read from the representative checkout
 * and every save fans out to each member of the group, like the panel's
 * boolean overrides, so a thread on any checkout sees the same list.
 */
export function ProjectPromptSnippetsSection(props: {
  representative: PromptSnippetTarget;
  members: readonly PromptSnippetTarget[];
  reportFailure: (title: string, result: AtomCommandResult<void, unknown>) => void;
}) {
  const { representative, members, reportFailure } = props;
  const snippets = useEnvironmentSettings(representative.environmentId, (settings) =>
    snippetsForProject(settings, representative.projectId),
  );
  const updateServerSettings = useAtomCommand(serverEnvironment.updateSettings, "saved prompt");
  const [editing, setEditing] = useState<{ id: string | null; name: string; text: string } | null>(
    null,
  );
  const [saving, setSaving] = useState(false);

  const store = async (next: readonly PromptSnippet[]) => {
    const offline = members.find((member) => !member.connected);
    if (offline !== undefined) {
      toastManager.add({
        type: "warning",
        title: "Prompt not saved",
        description: `Connect ${offline.label} and try again.`,
      });
      return false;
    }
    setSaving(true);
    try {
      for (const member of members) {
        const result = await updateServerSettings({
          environmentId: member.environmentId,
          input: { patch: promptSnippetsPatch(member.projectId, next) },
        });
        if (result._tag === "Failure") {
          reportFailure(
            `Failed to save prompts on ${member.label}`,
            mapAtomCommandResult(result, () => undefined),
          );
          return false;
        }
      }
      return true;
    } finally {
      setSaving(false);
    }
  };

  const submit = async () => {
    if (editing === null) return;
    const draft = promptSnippetDraft(editing.name, editing.text);
    if (draft === null) return;
    const id =
      editing.id ??
      nextPromptSnippetId(
        draft.name,
        snippets.map((item) => item.id),
      );
    const next = upsertPromptSnippet(snippets, { id, ...draft });
    if (next === null) {
      toastManager.add({
        type: "warning",
        title: "Prompt not saved",
        description: `A project keeps at most ${MAX_PROMPT_SNIPPETS_PER_PROJECT} saved prompts.`,
      });
      return;
    }
    if (await store(next)) setEditing(null);
  };

  const draftValid = editing !== null && promptSnippetDraft(editing.name, editing.text) !== null;

  return (
    <SettingsSection
      title="Prompts"
      headerAction={
        editing === null ? (
          <Button
            variant="ghost"
            size="sm"
            disabled={saving || snippets.length >= MAX_PROMPT_SNIPPETS_PER_PROJECT}
            onClick={() => setEditing({ id: null, name: "", text: "" })}
          >
            <PlusIcon /> Add prompt
          </Button>
        ) : null
      }
    >
      {snippets.length === 0 && editing === null ? (
        <SettingsRow
          title="No saved prompts"
          description="Saved prompts are fragments you reuse in this project's threads, inserted from the composer's Prompts tab."
        />
      ) : null}
      {snippets.map((snippet) =>
        editing?.id === snippet.id ? null : (
          <SettingsRow
            key={snippet.id}
            title={snippet.name}
            description={promptSnippetPreview(snippet.text)}
            control={
              <div className="flex items-center gap-1">
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={`Edit prompt ${snippet.name}`}
                  disabled={saving}
                  onClick={() =>
                    setEditing({ id: snippet.id, name: snippet.name, text: snippet.text })
                  }
                >
                  <PencilIcon />
                </Button>
                <Button
                  variant="ghost"
                  size="icon-sm"
                  aria-label={`Remove prompt ${snippet.name}`}
                  disabled={saving}
                  onClick={() => void store(removePromptSnippet(snippets, snippet.id))}
                >
                  <Trash2Icon />
                </Button>
              </div>
            }
          />
        ),
      )}
      {editing !== null ? (
        <SettingsRow title={editing.id === null ? "New prompt" : "Edit prompt"}>
          <div className="flex flex-col gap-2 pt-2">
            <Input
              size="sm"
              aria-label="Prompt name"
              placeholder="Name shown in the picker"
              maxLength={MAX_PROMPT_SNIPPET_NAME_LENGTH}
              value={editing.name}
              onChange={(event) => setEditing({ ...editing, name: event.target.value })}
            />
            <Textarea
              aria-label="Prompt text"
              placeholder="Text inserted into the composer"
              rows={4}
              maxLength={MAX_PROMPT_SNIPPET_TEXT_LENGTH}
              value={editing.text}
              onChange={(event) => setEditing({ ...editing, text: event.target.value })}
            />
            <div className="flex justify-end gap-2">
              <Button variant="ghost" size="sm" disabled={saving} onClick={() => setEditing(null)}>
                Cancel
              </Button>
              <Button size="sm" disabled={saving || !draftValid} onClick={() => void submit()}>
                Save
              </Button>
            </div>
          </div>
        </SettingsRow>
      ) : null}
    </SettingsSection>
  );
}
