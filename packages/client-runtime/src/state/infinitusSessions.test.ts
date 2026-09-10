import type { InfinitusSession, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  canSetSessionMode,
  sessionModeCommandArgs,
  sessionRow,
  sessionRows,
  sessionState,
} from "./infinitusSessions.ts";

function session(overrides: Partial<InfinitusSession> = {}): InfinitusSession {
  return { pid: 100, cwd: "/Users/me/work/limitless", kind: "interactive", ...overrides };
}

function snapshot(sessions: InfinitusSession[]): InfinitusSnapshot {
  return { available: true, fleets: [], sessions, commands: [] };
}

describe("sessionState", () => {
  it("maps the record's status words and treats anything else as unknown", () => {
    expect(sessionState("busy")).toBe("working");
    expect(sessionState("waiting")).toBe("waiting");
    expect(sessionState("idle")).toBe("idle");
    expect(sessionState("shell")).toBe("shell");
    expect(sessionState(null)).toBe("unknown");
    expect(sessionState("compacting")).toBe("unknown");
  });
});

describe("sessionRow", () => {
  it("titles a named session by name and a nameless one by its folder", () => {
    expect(sessionRow(session({ name: "peon", status: "busy" }))).toEqual({
      pid: 100,
      title: "peon",
      folder: "limitless",
      cwd: "/Users/me/work/limitless",
      state: "working",
      stateLabel: "working",
      kind: "interactive",
      permissionMode: "supervised",
    });
    expect(sessionRow(session({ name: null, cwd: "/tmp/proj/" })).title).toBe("proj");
  });

  it("reads a null or unknown permission mode as supervised", () => {
    expect(sessionRow(session({ permissionMode: null })).permissionMode).toBe("supervised");
    expect(sessionRow(session({ permissionMode: "plan" })).permissionMode).toBe("supervised");
    expect(sessionRow(session({ permissionMode: "bypassPermissions" })).permissionMode).toBe(
      "bypassPermissions",
    );
  });
});

describe("sessionRows", () => {
  it("puts waiting sessions first, then working, then the rest by title", () => {
    const rows = sessionRows(
      snapshot([
        session({ pid: 1, name: "zeta", status: "idle" }),
        session({ pid: 2, name: "beta", status: "busy" }),
        session({ pid: 3, name: "alpha", status: "waiting" }),
        session({ pid: 4, name: "gamma", status: "busy" }),
        session({ pid: 5, name: "omega", status: null }),
      ]),
    );
    expect(rows.map((row) => row.title)).toEqual(["alpha", "beta", "gamma", "zeta", "omega"]);
  });
});

describe("session-mode", () => {
  it("is offered only when the manifest lists the verb", () => {
    expect(canSetSessionMode([])).toBe(false);
    expect(
      canSetSessionMode([
        {
          name: "session-mode",
          args: ["<pid|name>", "<supervised|acceptEdits|bypassPermissions>"],
          options: [],
          effect: "write",
          summary: "",
          replyShape: "{mode?, label}",
        },
      ]),
    ).toBe(true);
  });

  it("addresses the session by pid", () => {
    expect(sessionModeCommandArgs(sessionRow(session({ pid: 4321 })), "acceptEdits")).toEqual({
      command: "session-mode",
      args: ["4321", "acceptEdits"],
    });
  });
});
