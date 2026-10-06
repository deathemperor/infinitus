import type { SDKResultMessage } from "@anthropic-ai/claude-agent-sdk";

import type { Options as ClaudeQueryOptions } from "@anthropic-ai/claude-agent-sdk";

/**
 * Reconnect (#832): the pure half. A turn whose transport goes away is not
 * failed on the spot: the adapter keeps the turn open, waits, and reopens
 * the CLI on the session id it already reported, with the same prompt the
 * server-update continuation sends. Only transport failures qualify; a model
 * or tool failure (a malformed tool call, an expired login, a usage limit)
 * fails the turn as before. Attempts are bounded and the wait grows.
 */

/** The wait before each attempt, in order; the length is the attempt cap. */
export const RECONNECT_BACKOFF_MILLIS: ReadonlyArray<number> = [
  5_000, 15_000, 60_000, 180_000, 600_000,
];
export const RECONNECT_MAX_ATTEMPTS = RECONNECT_BACKOFF_MILLIS.length;

export const RECONNECT_EXHAUSTED_MESSAGE = `Lost the connection to Claude after ${RECONNECT_MAX_ATTEMPTS} reconnect attempts. Send a message to continue.`;

/** The session-state reason while waiting; the web reads it as "waiting for the network". */
export function reconnectReason(attempt: number): string {
  return `reconnecting:${attempt}/${RECONNECT_MAX_ATTEMPTS}`;
}

/** The socket-level messages Node and undici raise when the network is gone. */
const TRANSPORT_ERROR_PATTERN =
  /ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|EHOSTUNREACH|ENETUNREACH|fetch failed|socket hang up|network error|network is unreachable/i;

export function isTransportErrorMessage(text: string): boolean {
  return TRANSPORT_ERROR_PATTERN.test(text);
}

/**
 * A result the CLI gave up on because the API was unreachable: repeated API
 * errors with no cause of its own reported earlier in the turn. A failure
 * hint (expired login, usage limit) means the turn already knows why it
 * failed, and that is never a transport problem; a 529 overload is the API
 * answering, and the CLI's own retries already covered it.
 */
export function isTransportResult(
  result: SDKResultMessage,
  failureHint: string | undefined,
): boolean {
  if (failureHint !== undefined) return false;
  return result.subtype !== "success" && result.terminal_reason === "api_error";
}

/**
 * The query options a reconnect reopens with: the same session, resumed on
 * the id the CLI reported, never a fresh or forked one.
 */
export function reconnectQueryOptions(
  options: ClaudeQueryOptions,
  resume: string,
): ClaudeQueryOptions {
  const {
    sessionId: _sessionId,
    forkSession: _forkSession,
    resumeSessionAt: _resumeSessionAt,
    ...rest
  } = options;
  return { ...rest, resume };
}
