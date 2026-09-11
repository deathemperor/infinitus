import { describe, expect, it } from "vite-plus/test";

import { deviceTokenOf, isMacAlertResponse } from "./alertPush.logic";

describe("deviceTokenOf", () => {
  it("takes the trimmed hex for this platform, nothing otherwise", () => {
    expect(deviceTokenOf({ type: "ios", data: " abc123 " }, "ios")).toBe("abc123");
    expect(deviceTokenOf({ type: "android", data: "abc123" }, "ios")).toBeNull();
    expect(deviceTokenOf({ type: "ios", data: "   " }, "ios")).toBeNull();
    expect(deviceTokenOf({ type: "ios", data: { token: "x" } }, "ios")).toBeNull();
    expect(deviceTokenOf(null, "ios")).toBeNull();
  });
});

describe("isMacAlertResponse", () => {
  it("matches a push with no custom data, aps included", () => {
    expect(isMacAlertResponse(response({ type: "push" }, { aps: { alert: {} } }))).toBe(true);
    expect(isMacAlertResponse(response({ type: "push" }, {}))).toBe(true);
    expect(isMacAlertResponse(response({ type: "push" }, null))).toBe(true);
  });

  it("leaves T3's agent pushes and the local alarms alone", () => {
    expect(isMacAlertResponse(response({ type: "push" }, { deepLink: "/threads/a/b" }))).toBe(
      false,
    );
    expect(isMacAlertResponse(response({ type: "date" }, { infinitus: "accounts" }))).toBe(false);
    expect(isMacAlertResponse(response(null, {}))).toBe(false);
  });

  function response(trigger: { type: string } | null, data: unknown) {
    return { notification: { request: { trigger, content: { data } } } };
  }
});
