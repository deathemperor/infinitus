import type { InfinitusSession, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { attentionSessionCount } from "./sessions.logic";

function session(overrides: Partial<InfinitusSession> = {}): InfinitusSession {
  return { pid: 1, cwd: "/work/proj", kind: "interactive", status: "idle", ...overrides };
}

function snapshot(overrides: Partial<InfinitusSnapshot> = {}): InfinitusSnapshot {
  return { available: true, fleets: [], sessions: [], commands: [], ...overrides };
}

describe("attentionSessionCount", () => {
  it("counts the sessions needing a person, none while loading or offline", () => {
    const sessions = [
      session({ pid: 1, name: "b", status: "busy" }),
      session({ pid: 2, name: "a", status: "waiting" }),
      session({ pid: 3, name: "c", status: "idle", needs: ["aws-login:prod"] }),
    ];
    expect(attentionSessionCount(snapshot({ sessions }))).toBe(2);
    expect(attentionSessionCount(snapshot({ available: false, sessions }))).toBe(0);
    expect(attentionSessionCount(null)).toBe(0);
  });
});
