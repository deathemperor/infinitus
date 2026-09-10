import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  attentionSessionCount,
  macSessionsView,
  sessionChoiceCommand,
  sessionMenuActions,
  sessionMenuChoice,
  sessionRowDetail,
} from "./sessions.logic";

const NOW = Date.parse("2026-09-10T12:00:00Z");

function session(overrides: Partial<InfinitusSession> = {}): InfinitusSession {
  return { pid: 1, cwd: "/work/proj", kind: "interactive", status: "idle", ...overrides };
}

function command(name: string, args: string[] = []): InfinitusManifestCommand {
  return { name, args, options: [], effect: "write", summary: "", replyShape: "" };
}

const ALL_VERBS = [
  command("session-mode"),
  command("show", ["popout|settings|session <pid|name>"]),
  command("nudge", ["<pid|name>"]),
];

function snapshot(overrides: Partial<InfinitusSnapshot> = {}): InfinitusSnapshot {
  return { available: true, fleets: [], sessions: [], commands: [], ...overrides };
}

describe("macSessionsView", () => {
  it("is null while loading, when the app is offline, and with no session", () => {
    expect(macSessionsView(null, NOW)).toBeNull();
    expect(macSessionsView(snapshot({ available: false, sessions: [session()] }), NOW)).toBeNull();
    expect(macSessionsView(snapshot(), NOW)).toBeNull();
  });

  it("orders the rows needing a person first, counts them, and reads the verbs from the manifest", () => {
    const sessions = [
      session({ pid: 1, name: "b", status: "busy" }),
      session({ pid: 2, name: "a", status: "waiting" }),
      session({ pid: 3, name: "c", status: "idle", needs: ["aws-login:prod"] }),
    ];
    const view = macSessionsView(snapshot({ sessions }), NOW);
    expect(view?.rows.map((row) => row.pid)).toEqual([2, 3, 1]);
    expect(view?.attentionCount).toBe(2);
    expect(view?.actions).toEqual({ setMode: false, show: false, nudge: false });
    expect(macSessionsView(snapshot({ sessions, commands: ALL_VERBS }), NOW)?.actions).toEqual({
      setMode: true,
      show: true,
      nudge: true,
    });
    expect(attentionSessionCount(snapshot({ sessions }))).toBe(2);
    expect(attentionSessionCount(null)).toBe(0);
  });
});

describe("sessionRowDetail", () => {
  it("is the state, then folder for a named row, then account and age when sent", () => {
    const rows = macSessionsView(
      snapshot({
        sessions: [
          session({ pid: 1, name: "peon", account: "death4", startedAt: "2026-09-10T09:00:00Z" }),
          session({ pid: 2, status: "busy" }),
        ],
      }),
      NOW,
    )!.rows;
    expect(sessionRowDetail(rows.find((row) => row.pid === 1)!)).toBe("idle · proj · death4 · 3h");
    expect(sessionRowDetail(rows.find((row) => row.pid === 2)!)).toBe("working");
  });
});

describe("session menu", () => {
  const [row] = macSessionsView(
    snapshot({ sessions: [session({ pid: 77, permissionMode: "acceptEdits" })] }),
    NOW,
  )!.rows;

  it("lists only the verbs the manifest offers, the current mode checked", () => {
    expect(sessionMenuActions(row!, { setMode: false, show: false, nudge: false })).toEqual([]);
    const actions = sessionMenuActions(row!, { setMode: true, show: true, nudge: true });
    expect(actions.map((action) => action.id)).toEqual(["show", "nudge", "mode"]);
    expect(actions[2]!.subactions!.map((action) => [action.id, action.state])).toEqual([
      ["mode:supervised", "off"],
      ["mode:acceptEdits", "on"],
      ["mode:bypassPermissions", "off"],
    ]);
  });

  it("maps ids back to choices and choices to commands by pid", () => {
    expect(sessionMenuChoice("show")).toEqual({ kind: "show" });
    expect(sessionMenuChoice("mode:bypassPermissions")).toEqual({
      kind: "mode",
      mode: "bypassPermissions",
    });
    expect(sessionMenuChoice("mode")).toBeNull();
    expect(sessionMenuChoice("mode:plan")).toBeNull();

    expect(sessionChoiceCommand(row!, { kind: "show" })).toEqual({
      command: "show",
      args: ["session", "77"],
      options: {},
    });
    expect(sessionChoiceCommand(row!, { kind: "nudge" })).toEqual({
      command: "nudge",
      args: ["77"],
      options: {},
    });
    expect(sessionChoiceCommand(row!, { kind: "mode", mode: "supervised" })).toEqual({
      command: "session-mode",
      args: ["77", "supervised"],
      options: {},
    });
    expect(sessionChoiceCommand(row!, { kind: "mode", mode: "acceptEdits" })).toBeNull();
  });
});
