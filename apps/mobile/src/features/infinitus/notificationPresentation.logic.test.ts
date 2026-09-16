import { describe, expect, it } from "vite-plus/test";

import { presentInForeground } from "./notificationPresentation.logic";

describe("presentInForeground", () => {
  it("shows an Infinitus account alert and an Infinitus alarm", () => {
    expect(
      presentInForeground(
        notification({ type: "push" }, { deepLink: "/settings/accounts", environmentId: "env" }),
      ),
    ).toBe(true);
    expect(presentInForeground(notification({ type: "date" }, { infinitus: "accounts" }))).toBe(
      true,
    );
    expect(presentInForeground(notification(null, { infinitus: "accounts", fireAt: 1 }))).toBe(
      true,
    );
  });

  it("leaves T3's pushes and other local notifications to the default", () => {
    expect(presentInForeground(notification({ type: "push" }, { deepLink: "/threads/a/b" }))).toBe(
      false,
    );
    expect(presentInForeground(notification({ type: "push" }, { aps: { alert: {} } }))).toBe(false);
    expect(
      presentInForeground(notification({ type: "date" }, { deepLink: "/settings/accounts" })),
    ).toBe(false);
    expect(presentInForeground(notification({ type: "timeInterval" }, { other: 1 }))).toBe(false);
    expect(presentInForeground(notification(null, undefined))).toBe(false);
  });

  function notification(trigger: { type: string } | null, data: unknown) {
    return { request: { trigger, content: { data } } };
  }
});
