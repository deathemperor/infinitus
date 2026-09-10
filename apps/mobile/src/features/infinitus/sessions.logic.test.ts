import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  isSessionPermissionMode,
  macSessionsView,
  sessionModeCommand,
  sessionModeMenuActions,
  waitingSessionCount,
} from "./sessions.logic";

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

describe("macSessionsView", () => {
  it("is null while loading, when the app is offline, and with no session", () => {
    expect(macSessionsView(null)).toBeNull();
    expect(macSessionsView(snapshot({ available: false, sessions: [session()] }))).toBeNull();
    expect(macSessionsView(snapshot())).toBeNull();
  });

  it("orders waiting first, counts them, and offers session-mode only from the manifest", () => {
    const sessions = [
      session({ pid: 1, name: "b", status: "busy" }),
      session({ pid: 2, name: "a", status: "waiting" }),
    ];
    const view = macSessionsView(snapshot({ sessions }));
    expect(view?.rows.map((row) => row.pid)).toEqual([2, 1]);
    expect(view?.waitingCount).toBe(1);
    expect(view?.canSetMode).toBe(false);
    expect(macSessionsView(snapshot({ sessions, commands: [sessionMode] }))?.canSetMode).toBe(true);
    expect(waitingSessionCount(snapshot({ sessions }))).toBe(1);
    expect(waitingSessionCount(null)).toBe(0);
  });
});

describe("session-mode menu", () => {
  it("checks the row's current mode and maps ids back to modes", () => {
    const [row] = macSessionsView(
      snapshot({ sessions: [session({ permissionMode: "acceptEdits" })] }),
    )!.rows;
    const actions = sessionModeMenuActions(row!);
    expect(actions.map((action) => [action.id, action.state])).toEqual([
      ["supervised", "off"],
      ["acceptEdits", "on"],
      ["bypassPermissions", "off"],
    ]);
    expect(isSessionPermissionMode("bypassPermissions")).toBe(true);
    expect(isSessionPermissionMode("plan")).toBe(false);
  });

  it("builds the command by pid and skips the mode already set", () => {
    const [row] = macSessionsView(snapshot({ sessions: [session({ pid: 77 })] }))!.rows;
    expect(sessionModeCommand(row!, "bypassPermissions")).toEqual({
      command: "session-mode",
      args: ["77", "bypassPermissions"],
      options: {},
    });
    expect(sessionModeCommand(row!, "supervised")).toBeNull();
  });
});
