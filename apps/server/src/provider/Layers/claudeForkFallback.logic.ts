import type {
  Options as ClaudeQueryOptions,
  SDKResultMessage,
} from "@anthropic-ai/claude-agent-sdk";

/**
 * Fork fallback (#270 E2, side questions #269 C): the pure half. Claude Code
 * writes one transcript line per content block, all sharing the API message
 * id, and `--resume-session-at` finds only the first line of a message. An
 * anchor recorded before the adapter learned that (any turn whose last
 * message had a thinking block and a text block) names a later line, and the
 * CLI answers `No message found with message.uuid of: …` and exits. When the
 * anchor was the source's latest completed turn, the session's end is the
 * same fork point (#941), so the first start is retried once without the
 * anchor. An anchor on an earlier turn fails plainly instead: landing at the
 * wrong turn would be worse than a refusal.
 */

const FORK_ANCHOR_MISSING_PATTERN = /no message found with message\.uuid/i;

export function isForkAnchorMissingResult(result: SDKResultMessage): boolean {
  return (
    result.subtype !== "success" &&
    "errors" in result &&
    Array.isArray(result.errors) &&
    result.errors.some(
      (error) => typeof error === "string" && FORK_ANCHOR_MISSING_PATTERN.test(error),
    )
  );
}

export const FORK_AT_END_MESSAGE =
  "The fork point was not found in the session's transcript; forked at the session's end instead.";

export const FORK_POINT_MISSING_MESSAGE =
  "Fork point not found in the session's transcript: this turn was recorded before fork points were fixed and cannot be forked. Fork the latest turn instead.";

/** The query options the retry forks with: the same fork, no anchor. */
export function forkAtEndQueryOptions(options: ClaudeQueryOptions): ClaudeQueryOptions {
  const { resumeSessionAt: _resumeSessionAt, ...rest } = options;
  return rest;
}
