import {
  MAX_PROMPT_SNIPPETS_PER_PROJECT,
  MAX_PROMPT_SNIPPET_NAME_LENGTH,
  MAX_PROMPT_SNIPPET_TEXT_LENGTH,
  type ProjectId,
  type PromptSnippet,
  type ServerSettings,
} from "@t3tools/contracts";

/** The project's saved snippets, empty when it has none or was cleared. */
export function snippetsForProject(
  settings: Pick<ServerSettings, "projectPromptSnippets">,
  projectId: ProjectId,
): readonly PromptSnippet[] {
  return settings.projectPromptSnippets[projectId] ?? [];
}

/** Trimmed, non-empty and inside the schema caps; null when unusable. */
export function promptSnippetDraft(
  name: string,
  text: string,
): { readonly name: string; readonly text: string } | null {
  const trimmedName = name.trim();
  const trimmedText = text.trim();
  if (trimmedName.length === 0 || trimmedName.length > MAX_PROMPT_SNIPPET_NAME_LENGTH) return null;
  if (trimmedText.length === 0 || trimmedText.length > MAX_PROMPT_SNIPPET_TEXT_LENGTH) return null;
  return { name: trimmedName, text: trimmedText };
}

/** A stable id from the name (`Review the diff` → `review-the-diff`), suffixed past a taken one. */
export function nextPromptSnippetId(name: string, existingIds: Iterable<string>): string {
  const taken = new Set(existingIds);
  const base =
    name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 48) || "snippet";
  if (!taken.has(base)) return base;
  let suffix = 2;
  while (taken.has(`${base}-${suffix}`)) suffix += 1;
  return `${base}-${suffix}`;
}

/** Adds or replaces one snippet; null when adding would pass the per-project cap. */
export function upsertPromptSnippet(
  snippets: readonly PromptSnippet[],
  snippet: PromptSnippet,
): readonly PromptSnippet[] | null {
  const index = snippets.findIndex((item) => item.id === snippet.id);
  if (index === -1) {
    if (snippets.length >= MAX_PROMPT_SNIPPETS_PER_PROJECT) return null;
    return [...snippets, snippet];
  }
  return snippets.map((item, at) => (at === index ? snippet : item));
}

export function removePromptSnippet(
  snippets: readonly PromptSnippet[],
  id: string,
): readonly PromptSnippet[] {
  return snippets.filter((item) => item.id !== id);
}

/** The settings patch that stores `snippets` for `projectId`; an empty list clears the entry. */
export function promptSnippetsPatch(
  projectId: ProjectId,
  snippets: readonly PromptSnippet[],
): { readonly projectPromptSnippets: Record<ProjectId, readonly PromptSnippet[] | null> } {
  return { projectPromptSnippets: { [projectId]: snippets.length === 0 ? null : snippets } };
}

/** The first line of the body, cut for a one-line preview. */
export function promptSnippetPreview(text: string, maxChars = 80): string {
  const firstLine = text.split(/\r?\n/, 1)[0]?.trim() ?? "";
  if (firstLine.length <= maxChars) return firstLine;
  return `${firstLine.slice(0, Math.max(1, maxChars - 1)).trimEnd()}…`;
}
