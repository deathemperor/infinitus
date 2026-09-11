/**
 * Approve-on-Mac pairing (#710) on the wire: the ask, and the poll that waits
 * for the Mac's decision. Both take the request function, the clock and the
 * timer as inputs so the tests drive them without a server or real time.
 */
import {
  type ApprovalOutcome,
  createdFromReply,
  PAIRING_APPROVAL_PATH,
  PAIRING_APPROVAL_POLL_PATH,
  POLL_INTERVAL_MS,
  pollReplyFromBody,
  WAIT_CAP_MS,
} from "./pairingApproval.logic";

/** One JSON POST: the status and the decoded body (null when not JSON).
    Rejects only when nothing answered. */
export type Post = (
  url: string,
  body: unknown,
  signal: AbortSignal,
) => Promise<{ readonly status: number; readonly body: unknown }>;

const fetchPost: Post = async (url, body, signal) => {
  const response = await fetch(url, {
    method: "POST",
    signal,
    headers: { "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(body),
  });
  let json: unknown = null;
  try {
    json = await response.json();
  } catch {
    json = null;
  }
  return { status: response.status, body: json };
};

/** Resolves after `ms`, or as soon as `signal` aborts. */
export type Sleep = (ms: number, signal: AbortSignal) => Promise<void>;

const timerSleep: Sleep = (ms, signal) =>
  new Promise((resolve) => {
    const done = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    signal.addEventListener("abort", done);
  });

export type AskResult =
  | {
      readonly kind: "asked";
      readonly id: string;
      readonly matchCode: string;
      /** When `waitForDecision` gives up, on the phone's clock. */
      readonly deadlineMillis: number;
    }
  | { readonly kind: "refused" }
  | { readonly kind: "unreachable" };

/** Files the request with the server at `origin`. Never throws. */
export async function askForApproval(input: {
  readonly origin: string;
  readonly deviceName: string;
  readonly os: string;
  readonly secret: string;
  readonly signal: AbortSignal;
  readonly post?: Post;
  readonly now?: () => number;
}): Promise<AskResult> {
  const post = input.post ?? fetchPost;
  const now = input.now ?? Date.now;
  let reply: Awaited<ReturnType<Post>>;
  try {
    reply = await post(
      `${input.origin}${PAIRING_APPROVAL_PATH}`,
      { deviceName: input.deviceName, os: input.os, secret: input.secret },
      input.signal,
    );
  } catch {
    return { kind: "unreachable" };
  }
  if (reply.status === 429) return { kind: "refused" };
  const created = reply.status === 200 ? createdFromReply(reply.body) : null;
  return created === null
    ? { kind: "unreachable" }
    : { kind: "asked", ...created, deadlineMillis: now() + WAIT_CAP_MS };
}

/**
 * Polls until the Mac decides, the request expires (the server's 404, or the
 * deadline with nothing answering), or `signal` aborts. A poll that fails to
 * reach the server is retried on the next tick: Wi‑Fi hiccups are the normal
 * case, and the server keeps the decision until the request expires. Never
 * throws.
 */
export async function waitForDecision(input: {
  readonly origin: string;
  readonly id: string;
  readonly secret: string;
  readonly deadlineMillis: number;
  readonly signal: AbortSignal;
  readonly post?: Post;
  readonly now?: () => number;
  readonly sleep?: Sleep;
}): Promise<ApprovalOutcome> {
  const post = input.post ?? fetchPost;
  const now = input.now ?? Date.now;
  const sleep = input.sleep ?? timerSleep;
  const url = `${input.origin}${PAIRING_APPROVAL_POLL_PATH}`;
  const body = { id: input.id, secret: input.secret };
  while (!input.signal.aborted) {
    if (now() >= input.deadlineMillis) return { kind: "expired" };
    try {
      const reply = await post(url, body, input.signal);
      if (reply.status === 404) return { kind: "expired" };
      const decision = reply.status === 200 ? pollReplyFromBody(reply.body) : null;
      if (decision?.state === "approved") {
        return { kind: "approved", credential: decision.credential };
      }
      if (decision?.state === "denied") return { kind: "denied" };
    } catch {
      // Unreachable for now; the next tick tries again until the deadline.
    }
    if (input.signal.aborted) break;
    await sleep(POLL_INTERVAL_MS, input.signal);
  }
  return { kind: "cancelled" };
}
