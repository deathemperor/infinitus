import { describe, expect, it } from "vite-plus/test";

import { reconnectingNotice, reconnectingRowLabel } from "./reconnecting.logic";

describe("reconnecting (#832)", () => {
  it("reads the adapter's reconnecting reason on a running session", () => {
    const session = { status: "running", statusReason: "reconnecting:2/5" };
    expect(reconnectingNotice(session)).toBe("Waiting for the network. Reconnect attempt 2 of 5.");
    expect(reconnectingRowLabel(session)).toBe("Reconnecting 2/5");
  });

  it("shows nothing for other reasons, other statuses, or no session", () => {
    expect(reconnectingNotice({ status: "running", statusReason: "api_retry:1/10" })).toBeNull();
    expect(reconnectingNotice({ status: "running", statusReason: null })).toBeNull();
    expect(reconnectingNotice({ status: "running" })).toBeNull();
    expect(reconnectingRowLabel({ status: "error", statusReason: "reconnecting:1/5" })).toBeNull();
    expect(reconnectingRowLabel(null)).toBeNull();
  });
});
