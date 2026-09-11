import { describe, expect, it } from "vite-plus/test";

import { eventRepeatKey, eventToast, toastAction } from "./infinitusEventToasts.logic";

describe("eventToast", () => {
  it("maps the three kinds worth interrupting for", () => {
    expect(eventToast({ icon: "battery.0percent", text: "all exhausted" })).toEqual({
      type: "error",
      title: "All accounts exhausted",
      description: "all exhausted",
      kind: "limit",
    });
    expect(
      eventToast({
        icon: "arrow.triangle.2.circlepath",
        text: "switched one@example.com → two@example.com",
      }),
    ).toEqual({
      type: "info",
      title: "Switched accounts",
      description: "switched one@example.com → two@example.com",
      kind: "switch",
    });
    expect(
      eventToast({ icon: "hand.raised", text: "headless session 4243 is waiting for an answer" }),
    ).toEqual({
      type: "warning",
      title: "A session is waiting for you",
      description: "headless session 4243 is waiting for an answer",
      kind: "waiting",
      pid: 4243,
    });
  });

  it("ignores the per-minute noise and everything it does not know", () => {
    expect(eventToast({ icon: "clock.arrow.circlepath", text: "poll" })).toBeNull();
    expect(
      eventToast({ icon: "hand.raised", text: "no switch — already consuming soonest" }),
    ).toBeNull();
    expect(eventToast({ icon: "heart.slash", text: "one@example.com hit a limit" })).toBeNull();
    expect(eventToast({ icon: "", text: "" })).toBeNull();
  });
});

describe("eventToast with the row's own kind (#630)", () => {
  it("lets the kind decide, the icon only standing in when it is absent", () => {
    expect(
      eventToast({ kind: "limit", icon: "battery.0percent", text: "all exhausted" }),
    ).toMatchObject({ type: "error" });
    expect(
      eventToast({ kind: "switch", icon: "arrow.triangle.2.circlepath", text: "switched a → b" }),
    ).toMatchObject({ type: "info" });
    expect(
      eventToast({
        kind: "other",
        icon: "hand.raised",
        text: "headless session 7 is waiting for an answer",
      }),
    ).toMatchObject({ type: "warning", pid: 7 });
    // A kind the icon would have misread: the kind wins.
    expect(eventToast({ kind: "hook", icon: "battery.0percent", text: "allowed x" })).toBeNull();
    expect(eventToast({ kind: "death", icon: "heart.slash", text: "a hit a limit" })).toBeNull();
    expect(
      eventToast({ kind: "other", icon: "hand.raised", text: "no switch — already consuming" }),
    ).toBeNull();
  });
});

describe("eventRepeatKey", () => {
  it("is the icon and text, so a re-emitted line reads as the same news", () => {
    expect(eventRepeatKey({ icon: "battery.0percent", text: "all exhausted" })).toBe(
      eventRepeatKey({ icon: "battery.0percent", text: "all exhausted" }),
    );
    expect(eventRepeatKey({ icon: "battery.0percent", text: "all exhausted" })).not.toBe(
      eventRepeatKey({ icon: "hand.raised", text: "all exhausted" }),
    );
  });
});

describe("toastAction", () => {
  const withSession = [{ name: "show", args: ["popout|settings|session <pid|name>"] }];
  const settingsOnly = [{ name: "show", args: ["settings"] }];

  it("opens the session's window only while the build's show takes a session (#612)", () => {
    expect(toastAction({ kind: "waiting", pid: 4243 }, withSession)).toEqual({
      kind: "command",
      args: ["session", "4243"],
    });
  });

  it("never sends show without a session: the retired pop-out gives way to this app's pages (#670)", () => {
    expect(toastAction({ kind: "waiting", pid: 4243 }, settingsOnly)).toEqual({
      kind: "navigate",
      to: "/activity",
    });
    expect(toastAction({ kind: "waiting" }, withSession)).toEqual({
      kind: "navigate",
      to: "/activity",
    });
    expect(toastAction({ kind: "waiting", pid: 4243 }, [])).toEqual({
      kind: "navigate",
      to: "/activity",
    });
  });

  it("sends account news to the accounts page", () => {
    expect(toastAction({ kind: "limit" }, withSession)).toEqual({
      kind: "navigate",
      to: "/accounts",
    });
    expect(toastAction({ kind: "switch" }, settingsOnly)).toEqual({
      kind: "navigate",
      to: "/accounts",
    });
  });
});
