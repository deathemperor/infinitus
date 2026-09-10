import { describe, expect, it } from "vite-plus/test";

import { eventRepeatKey, eventToast } from "./infinitusEventToasts.logic";

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
