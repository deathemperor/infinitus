import { describe, expect, it } from "vite-plus/test";

import { presentInForeground } from "./notificationPresentation.logic";

describe("presentInForeground", () => {
  it("shows an Infinitus account alert and an Infinitus alarm", () => {
    expect(
      presentInForeground(
        push({ aps: { alert: {} }, environmentId: "env", deepLink: "/settings/accounts" }),
      ),
    ).toBe(true);
    expect(presentInForeground(local({ type: "date" }, { infinitus: "accounts" }))).toBe(true);
    expect(presentInForeground(local(null, { infinitus: "accounts", fireAt: 1 }))).toBe(true);
  });

  it("leaves T3's pushes and other local notifications to the default", () => {
    expect(
      presentInForeground(
        push({ aps: { alert: {} }, environmentId: "env", deepLink: "/threads/a/b" }),
      ),
    ).toBe(false);
    expect(presentInForeground(push({ aps: { alert: {} } }))).toBe(false);
    expect(presentInForeground(local({ type: "date" }, { deepLink: "/settings/accounts" }))).toBe(
      false,
    );
    expect(presentInForeground(local({ type: "timeInterval" }, { other: 1 }))).toBe(false);
    expect(presentInForeground(local(null, undefined))).toBe(false);
  });

  /** A remote push as iOS hands it over: the payload on the trigger, `data`
      empty (expo-notifications reads only a `body` key into it). */
  function push(payload: Record<string, unknown>) {
    return { request: { trigger: { type: "push", payload }, content: {} } };
  }

  function local(trigger: { type: string } | null, data: unknown) {
    return { request: { trigger, content: { data } } };
  }
});
