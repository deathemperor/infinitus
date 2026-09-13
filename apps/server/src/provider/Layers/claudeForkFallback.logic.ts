import type {
  Options as ClaudeQueryOptions,
  SDKResultMessage,
} from "@anthropic-ai/claude-agent-sdk";

/**
 * Fork fallback (#270 E2, side questions #269 C): the pure half. An anchor
 * the CLI cannot resolve makes it answer `No message found with
 * message.uuid of: …` and exit. Two causes, both permanent for that anchor:
 * Claude Code writes one transcript line per content block, all sharing the
 * API message id, and `--resume-session-at` finds only the first line of a
 * message (an anchor recorded before the adapter learned that names a later
 * line); and the CLI addresses only the messages after the transcript's
 * newest compaction boundary, so every anchor older than the last compaction
 * stops resolving. When the anchor was the source's latest completed turn,
 * the session's end is the same fork point (#941), so the start is retried
 * once without the anchor. An anchor on an earlier turn fails plainly
 * instead: landing at the wrong turn would be worse than a refusal.
 *
 * The refusal can arrive before the thread's first `sendTurn` — the CLI
 * exits while reading its options, without waiting for a prompt — so the
 * adapter runs this fallback with or without an open turn.
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
