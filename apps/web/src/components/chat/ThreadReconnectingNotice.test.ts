import { describe, expect, it } from "vite-plus/test";

import { reconnectingNotice } from "./ThreadReconnectingNotice";

describe("reconnectingNotice (#832)", () => {
  it("reads the adapter's reconnecting reason on a running session", () => {
    expect(reconnectingNotice({ status: "running", statusReason: "reconnecting:2/5" })).toBe(
      "Waiting for the network. Reconnect attempt 2 of 5.",
    );
  });

  it("shows nothing for other reasons, other statuses, or no session", () => {
    expect(reconnectingNotice({ status: "running", statusReason: "api_retry:1/10" })).toBeNull();
    expect(reconnectingNotice({ status: "running", statusReason: null })).toBeNull();
    expect(reconnectingNotice({ status: "running" })).toBeNull();
    expect(reconnectingNotice({ status: "error", statusReason: "reconnecting:1/5" })).toBeNull();
    expect(reconnectingNotice(null)).toBeNull();
  });
});
