import { describe, expect, it } from "vite-plus/test";

import {
  attentionCount,
  attentionNotificationTitle,
  legacyNotificationMode,
  quietForViewer,
} from "./infinitusNotifications.logic";

describe("attentionNotificationTitle (#1032)", () => {
  it("names the states that wait on the user, upstream's and the fork's", () => {
    expect(attentionNotificationTitle("approval")).toBe("Approval needed");
    expect(attentionNotificationTitle("input")).toBe("Input needed");
    expect(attentionNotificationTitle("held")).toBe("Held for headroom");
    expect(attentionNotificationTitle("failed")).toBe("Session failed");
  });

  it("is null for every other state", () => {
    expect(attentionNotificationTitle("working")).toBeNull();
    expect(attentionNotificationTitle("ready")).toBeNull();
    expect(attentionNotificationTitle("limited")).toBeNull();
  });
});

describe("quietForViewer", () => {
  it("keeps the thread on screen quiet only while the window has focus", () => {
    const focused = { visibilityState: "visible" as const, hasFocus: () => true };
    const blurred = { visibilityState: "visible" as const, hasFocus: () => false };
    expect(quietForViewer("env:t1", "env:t1", focused)).toBe(true);
    expect(quietForViewer("env:t1", "env:t2", focused)).toBe(false);
    expect(quietForViewer("env:t1", "env:t1", blurred)).toBe(false);
    expect(quietForViewer(null, "env:t1", focused)).toBe(false);
  });
});

describe("legacyNotificationMode", () => {
  it("maps the #270 B toggles and the #270 H sound onto one mode", () => {
    expect(legacyNotificationMode({}, false)).toBe("notifications");
    expect(legacyNotificationMode({}, true)).toBe("notifications-and-sound");
    const allOff = {
      desktopNotifyOnApproval: false,
      desktopNotifyOnInput: false,
      desktopNotifyOnHeld: false,
      desktopNotifyOnFailure: false,
    };
    expect(legacyNotificationMode(allOff, true)).toBe("sound");
    expect(legacyNotificationMode(allOff, false)).toBe("off");
    expect(legacyNotificationMode(null, true)).toBe("sound");
    expect(legacyNotificationMode(null, false)).toBe("off");
    expect(legacyNotificationMode({ ...allOff, desktopNotifyOnInput: true }, false)).toBe(
      "notifications",
    );
  });
});

describe("attentionCount", () => {
  it("counts the threads waiting on the user", () => {
    expect(
      attentionCount([
        { status: "approval" },
        { status: "input" },
        { status: "held" },
        { status: "working" },
      ]),
    ).toBe(2);
  });
});
