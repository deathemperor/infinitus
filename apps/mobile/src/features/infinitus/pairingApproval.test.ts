import { describe, expect, it } from "vite-plus/test";

import { askForApproval, type Post, waitForDecision } from "./pairingApproval";
import { EXPIRY_GRACE_MS, POLL_INTERVAL_MS } from "./pairingApproval.logic";

const ORIGIN = "http://192.168.2.19:3773";
const SECRET = "0123456789abcdef0123456789abcdef";

/** A stubbed server: a list of replies handed out in order, the requests kept. */
function server(replies: ReadonlyArray<{ status: number; body: unknown } | Error>) {
  const requests: Array<{ url: string; body: unknown }> = [];
  const queue = [...replies];
  const post: Post = async (url, body) => {
    requests.push({ url, body });
    const next = queue.shift();
    if (next === undefined) throw new Error("no reply scripted");
    if (next instanceof Error) throw next;
    return next;
  };
  return { post, requests };
}

/** A clock the sleeps advance, so a poll loop runs without real time. */
function fakeClock(start = 1_000_000) {
  let now = start;
  return {
    now: () => now,
    sleep: async (ms: number) => {
      now += ms;
    },
    set: (millis: number) => {
      now = millis;
    },
  };
}

describe("askForApproval", () => {
  it("posts the phone's request and returns the match code with a deadline", async () => {
    const { post, requests } = server([
      {
        status: 200,
        body: { id: "req-1", matchCode: "AB12", expiresAt: "2026-09-11T10:02:00.000Z" },
      },
    ]);
    const asked = await askForApproval({
      origin: ORIGIN,
      deviceName: "Loc's iPhone",
      os: "ios",
      secret: SECRET,
      signal: new AbortController().signal,
      post,
    });
    expect(asked).toEqual({
      kind: "asked",
      id: "req-1",
      matchCode: "AB12",
      deadlineMillis: Date.parse("2026-09-11T10:02:00.000Z") + EXPIRY_GRACE_MS,
    });
    expect(requests).toEqual([
      {
        url: `${ORIGIN}/api/infinitus/pairing-approval`,
        body: { deviceName: "Loc's iPhone", os: "ios", secret: SECRET },
      },
    ]);
  });

  it("reports a full server, and anything that is not a fork server, without throwing", async () => {
    const base = { origin: ORIGIN, deviceName: "iPhone", os: "ios", secret: SECRET };
    const signal = new AbortController().signal;
    const full = server([{ status: 429, body: { _tag: "PairingApprovalRefused" } }]);
    expect(await askForApproval({ ...base, signal, post: full.post })).toEqual({ kind: "refused" });
    const dead = server([new TypeError("Network request failed")]);
    expect(await askForApproval({ ...base, signal, post: dead.post })).toEqual({
      kind: "unreachable",
    });
    const other = server([{ status: 200, body: "<html>" }]);
    expect(await askForApproval({ ...base, signal, post: other.post })).toEqual({
      kind: "unreachable",
    });
    const upstream = server([{ status: 404, body: null }]);
    expect(await askForApproval({ ...base, signal, post: upstream.post })).toEqual({
      kind: "unreachable",
    });
  });
});

describe("waitForDecision", () => {
  const base = { origin: ORIGIN, id: "req-1", secret: SECRET };

  it("polls while pending and hands over the credential on approval", async () => {
    const clock = fakeClock();
    const { post, requests } = server([
      { status: 200, body: { state: "pending" } },
      { status: 200, body: { state: "pending" } },
      {
        status: 200,
        body: { state: "approved", credential: "cred-1", expiresAt: "2026-09-11T10:02:00Z" },
      },
    ]);
    const outcome = await waitForDecision({
      ...base,
      deadlineMillis: clock.now() + 120_000,
      signal: new AbortController().signal,
      post,
      now: clock.now,
      sleep: clock.sleep,
    });
    expect(outcome).toEqual({ kind: "approved", credential: "cred-1" });
    expect(requests).toHaveLength(3);
    expect(requests[0]).toEqual({
      url: `${ORIGIN}/api/infinitus/pairing-approval/poll`,
      body: { id: "req-1", secret: SECRET },
    });
    expect(clock.now()).toBe(1_000_000 + 2 * POLL_INTERVAL_MS);
  });

  it("ends on the Mac's denial", async () => {
    const clock = fakeClock();
    const { post } = server([{ status: 200, body: { state: "denied" } }]);
    const outcome = await waitForDecision({
      ...base,
      deadlineMillis: clock.now() + 120_000,
      signal: new AbortController().signal,
      post,
      now: clock.now,
      sleep: clock.sleep,
    });
    expect(outcome).toEqual({ kind: "denied" });
  });

  it("treats the server's 404 as expired", async () => {
    const clock = fakeClock();
    const { post } = server([
      { status: 200, body: { state: "pending" } },
      { status: 404, body: { _tag: "PairingApprovalNotFound" } },
    ]);
    const outcome = await waitForDecision({
      ...base,
      deadlineMillis: clock.now() + 120_000,
      signal: new AbortController().signal,
      post,
      now: clock.now,
      sleep: clock.sleep,
    });
    expect(outcome).toEqual({ kind: "expired" });
  });

  it("retries past a network error and gives up at the deadline when nothing answers", async () => {
    const clock = fakeClock();
    const { post, requests } = server([
      new TypeError("Network request failed"),
      { status: 200, body: { state: "pending" } },
      new TypeError("Network request failed"),
      new TypeError("Network request failed"),
    ]);
    const outcome = await waitForDecision({
      ...base,
      deadlineMillis: clock.now() + 4 * POLL_INTERVAL_MS,
      signal: new AbortController().signal,
      post,
      now: clock.now,
      sleep: clock.sleep,
    });
    expect(outcome).toEqual({ kind: "expired" });
    expect(requests).toHaveLength(4);
  });

  it("reports cancelled when the wait is aborted, even mid-request", async () => {
    const controller = new AbortController();
    const clock = fakeClock();
    const post: Post = async () => {
      controller.abort();
      throw new DOMException("Aborted", "AbortError");
    };
    const outcome = await waitForDecision({
      ...base,
      deadlineMillis: clock.now() + 120_000,
      signal: controller.signal,
      post,
      now: clock.now,
      sleep: clock.sleep,
    });
    expect(outcome).toEqual({ kind: "cancelled" });
  });
});
