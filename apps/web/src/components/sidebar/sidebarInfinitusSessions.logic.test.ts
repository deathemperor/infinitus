import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import { sessionCommandErrorMessage, sidebarSessionsView } from "./sidebarInfinitusSessions.logic";

function session(overrides: Partial<InfinitusSession> = {}): InfinitusSession {
  return { pid: 1, cwd: "/work/proj", kind: "interactive", status: "idle", ...overrides };
}

const sessionMode: InfinitusManifestCommand = {
  name: "session-mode",
  args: ["<pid|name>", "<supervised|acceptEdits|bypassPermissions>"],
  options: [],
  effect: "write",
  summary: "",
  replyShape: "{mode?, label}",
};

function snapshot(overrides: Partial<InfinitusSnapshot> = {}): InfinitusSnapshot {
  return { available: true, fleets: [], sessions: [], commands: [], ...overrides };
}

describe("sidebarSessionsView", () => {
  it("is absent without the capability, a snapshot, an available app, or any session", () => {
    expect(sidebarSessionsView({ capability: undefined, snapshot: snapshot() })).toBeNull();
    expect(sidebarSessionsView({ capability: true, snapshot: null })).toBeNull();
    expect(
      sidebarSessionsView({
        capability: true,
        snapshot: snapshot({ available: false, sessions: [session()] }),
      }),
    ).toBeNull();
    expect(sidebarSessionsView({ capability: true, snapshot: snapshot() })).toBeNull();
  });

  it("counts the rows waiting on a person and offers session-mode only from the manifest", () => {
    const sessions = [
      session({ pid: 1, status: "waiting" }),
      session({ pid: 2, status: "busy" }),
      session({ pid: 3, status: "waiting" }),
    ];
    const without = sidebarSessionsView({ capability: true, snapshot: snapshot({ sessions }) });
    expect(without?.rows.map((row) => row.pid)).toEqual([1, 3, 2]);
    expect(without?.waitingCount).toBe(2);
    expect(without?.canSetMode).toBe(false);

    const withVerb = sidebarSessionsView({
      capability: true,
      snapshot: snapshot({ sessions, commands: [sessionMode] }),
    });
    expect(withVerb?.canSetMode).toBe(true);
  });
});

describe("sessionCommandErrorMessage", () => {
  it("uses the words the error carries, else a plain fallback", () => {
    expect(
      sessionCommandErrorMessage({ _tag: "InfinitusCommandFailed", error: "no such session" }),
    ).toBe("no such session");
    expect(sessionCommandErrorMessage({ _tag: "InfinitusUnavailable", cause: "offline" })).toBe(
      "offline",
    );
    expect(sessionCommandErrorMessage(new Error("boom"))).toBe("boom");
    expect(sessionCommandErrorMessage("x")).toBe("The command failed.");
  });
});
