import type { PromptSnippet } from "@t3tools/contracts";

import type { ComposerCommandItem } from "./ComposerCommandPopover";

/**
 * The phone's read-only half of per-project prompt snippets (#270 G): the
 * list lives in the project's server settings (`projectPromptSnippets`, saved
 * from the desktop's Settings › Projects › Prompts) and reaches the composer's
 * `/` menu through `useProjectPromptSnippets`; editing stays on the desktop.
 * Pure rows here, so the menu hook's tests stay clear of the state modules.
 */

/** The first line of the body, cut for the row's description. */
export function promptSnippetPreview(text: string, maxChars = 60): string {
  const firstLine = text.split(/\r?\n/, 1)[0]?.trim() ?? "";
  if (firstLine.length <= maxChars) return firstLine;
  return `${firstLine.slice(0, Math.max(1, maxChars - 1)).trimEnd()}…`;
}

/**
 * The snippets that match the `/` menu's query by name (case insensitive, a
 * leading `/` or `prompt:` ignored) as popover rows, in saved order.
 */
export function promptSnippetCommandItems(
  snippets: readonly PromptSnippet[],
  query: string,
): ComposerCommandItem[] {
  const needle = query
    .trim()
    .toLowerCase()
    .replace(/^\/+/, "")
    .replace(/^prompt:/, "");
  return snippets
    .filter((snippet) => needle.length === 0 || snippet.name.toLowerCase().includes(needle))
    .map((snippet) => ({
      id: `prompt:${snippet.id}`,
      type: "prompt-snippet" as const,
      snippet,
      label: snippet.name,
      description: promptSnippetPreview(snippet.text),
    }));
}
