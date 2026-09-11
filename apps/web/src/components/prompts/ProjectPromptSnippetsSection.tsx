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

/**
 * Settings › Projects › Prompts (#270 G): the project's saved snippets with
 * add, edit and remove, stored in the project's server settings under
 * `projectPromptSnippets`. A grouped project reads and writes its
 * representative checkout; the composer reads the checkout the thread runs
 * in, so siblings with a divergent list show their own.
 */
export function ProjectPromptSnippetsSection(props: {
  environmentId: EnvironmentId;
  projectId: ProjectId;
  /** Whether the environment is connected; edits are refused otherwise. */
  connected: boolean;
  reportFailure: (title: string, result: AtomCommandResult<void, unknown>) => void;
}) {
  const { environmentId, projectId, connected, reportFailure } = props;
  const snippets = useEnvironmentSettings(environmentId, (settings) =>
    snippetsForProject(settings, projectId),
  );
  const updateServerSettings = useAtomCommand(serverEnvironment.updateSettings, "saved prompt");
  const [editing, setEditing] = useState<{ id: string | null; name: string; text: string } | null>(
    null,
  );
  const [saving, setSaving] = useState(false);

  const store = async (next: readonly PromptSnippet[]) => {
    if (!connected) {
      toastManager.add({
        type: "warning",
        title: "Prompt not saved",
        description: "Connect this machine and try again.",
      });
      return false;
    }
    setSaving(true);
    try {
      const result = await updateServerSettings({
        environmentId,
        input: { patch: promptSnippetsPatch(projectId, next) },
      });
      if (result._tag === "Failure") {
        reportFailure(
          "Failed to save prompts",
          mapAtomCommandResult(result, () => undefined),
        );
        return false;
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
