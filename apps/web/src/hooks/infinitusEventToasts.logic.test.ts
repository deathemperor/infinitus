import { describe, expect, it } from "vite-plus/test";

import { eventRepeatKey, eventToast, showCommandArgs } from "./infinitusEventToasts.logic";

describe("eventToast", () => {
  it("maps the three kinds worth interrupting for", () => {
    expect(eventToast({ icon: "battery.0percent", text: "all exhausted" })).toEqual({
      type: "error",
      title: "All accounts exhausted",
      description: "all exhausted",
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
    });
    expect(
      eventToast({ icon: "hand.raised", text: "headless session 4243 is waiting for an answer" }),
    ).toEqual({
      type: "warning",
      title: "A session is waiting for you",
      description: "headless session 4243 is waiting for an answer",
      action: "show-popout",
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

describe("showCommandArgs", () => {
  const withSession = [{ name: "show", args: ["popout|settings|session <pid|name>"] }];
  const without = [{ name: "show", args: ["popout|settings|wall"] }];

  it("targets the session's window when the toast names one and the build's show takes it", () => {
    expect(showCommandArgs({ pid: 4243 }, withSession)).toEqual(["session", "4243"]);
    expect(showCommandArgs({ pid: 4243 }, without)).toEqual(["popout"]);
    expect(showCommandArgs({}, withSession)).toEqual(["popout"]);
    expect(showCommandArgs({ pid: 4243 }, [])).toEqual(["popout"]);
  });
});
