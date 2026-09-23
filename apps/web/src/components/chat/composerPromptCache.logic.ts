import {
  type PromptCacheState,
  promptCacheRemainingLabel,
  promptCacheTtlLabel,
} from "@infinitus/shared/threadUsage";

import { formatContextWindowTokens } from "~/lib/contextWindow";

/** Fork: the composer's prompt-cache tooltip — what the state means for the
    next message. `contextTokens` is the context the next message would
    re-send, when the context meter knows it. */
export function promptCacheDetail(state: PromptCacheState, contextTokens: number | null): string {
  if (state.kind === "cold") {
    const size =
      contextTokens !== null && contextTokens > 0
        ? ` (≈ ${formatContextWindowTokens(contextTokens)} tokens)`
        : "";
    const cause =
      state.reason === "restart"
        ? `The agent's session has stopped (Stop, an error, a restart or 30 idle minutes), and resuming it usually re-writes the whole context${size} even before the cache expires`
        : `Prompt cache expired. The next message re-writes the whole context${size} instead of reading it from cache`;
    return `${cause}; a new thread may be cheaper if this history is not needed.`;
  }
  return `Prompt cache warm for ${promptCacheRemainingLabel(state.remainingMs)} more (${promptCacheTtlLabel(state.ttlMs)} cache). A message before then reads the context from cache; each turn restarts the clock.`;
}
