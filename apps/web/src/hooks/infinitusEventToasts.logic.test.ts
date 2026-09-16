import { describe, expect, it } from "vite-plus/test";

import { eventRepeatKey, eventToast } from "./infinitusEventToasts.logic";

describe("eventToast", () => {
  it("maps the two kinds worth interrupting for", () => {
    expect(eventToast({ icon: "battery.0percent", text: "all exhausted" })).toEqual({
      type: "error",
      title: "All accounts exhausted",
      description: "all exhausted",
      kind: "limit",
      urgent: true,
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
      urgent: false,
    });
  });

  it("ignores the per-minute noise and everything it does not know", () => {
    expect(eventToast({ icon: "clock.arrow.circlepath", text: "poll" })).toBeNull();
    expect(
      eventToast({ icon: "hand.raised", text: "no switch — already consuming soonest" }),
    ).toBeNull();
    expect(
      eventToast({ icon: "hand.raised", text: "headless session 4243 is waiting for an answer" }),
    ).toBeNull();
    // One account of several hitting its limit is the Accounts page's news,
    // not a banner's — the app announces the fleet going out, not each death.
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
    // A kind the icon would have misread: the kind wins.
    expect(eventToast({ kind: "hook", icon: "battery.0percent", text: "allowed x" })).toBeNull();
    expect(eventToast({ kind: "death", icon: "heart.slash", text: "a hit a limit" })).toBeNull();
    expect(
      eventToast({ kind: "other", icon: "hand.raised", text: "no switch — already consuming" }),
    ).toBeNull();
  });
});

describe("the app's own announcements", () => {
  it("carries an alert whole, split the way the app's banner is", () => {
    expect(
      eventToast({
        kind: "alert",
        icon: "exclamationmark.triangle",
        text: "all 3 accounts exhausted — nothing left to switch to",
      }),
    ).toEqual({
      type: "error",
      title: "all 3 accounts exhausted",
      description: "nothing left to switch to",
      kind: "alert",
      urgent: true,
    });
  });

  it("makes a notice an info toast that does not interrupt", () => {
    expect(
      eventToast({ kind: "notice", icon: "heart.fill", text: "all accounts are back" }),
    ).toEqual({ type: "info", title: "all accounts are back", kind: "notice", urgent: false });
  });

  it("keeps an em dash inside the detail — the first one splits", () => {
    expect(
      eventToast({ kind: "notice", icon: "heart.fill", text: "a is back — reset early — by 2h" }),
    ).toMatchObject({ title: "a is back", description: "reset early — by 2h" });
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
