import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  sessionCommandErrorMessage,
  sessionRowDetail,
  sidebarSessionsView,
} from "./sidebarInfinitusSessions.logic";

const NOW = Date.parse("2026-09-10T12:00:00Z");

function session(overrides: Partial<InfinitusSession> = {}): InfinitusSession {
  return { pid: 1, cwd: "/work/proj", kind: "interactive", status: "idle", ...overrides };
}

function command(name: string, args: string[] = []): InfinitusManifestCommand {
  return { name, args, options: [], effect: "write", summary: "", replyShape: "" };
}

function snapshot(overrides: Partial<InfinitusSnapshot> = {}): InfinitusSnapshot {
  return { available: true, fleets: [], sessions: [], commands: [], ...overrides };
}

describe("sidebarSessionsView", () => {
  it("is absent without the capability, a snapshot, an available app, or any session", () => {
    expect(
      sidebarSessionsView({ capability: undefined, snapshot: snapshot(), now: NOW }),
    ).toBeNull();
    expect(sidebarSessionsView({ capability: true, snapshot: null, now: NOW })).toBeNull();
    expect(
      sidebarSessionsView({
        capability: true,
        snapshot: snapshot({ available: false, sessions: [session()] }),
        now: NOW,
      }),
    ).toBeNull();
    expect(sidebarSessionsView({ capability: true, snapshot: snapshot(), now: NOW })).toBeNull();
  });

  it("counts the rows needing a person and offers only the verbs the manifest lists", () => {
    const sessions = [
      session({ pid: 1, status: "waiting" }),
      session({ pid: 2, status: "busy" }),
      session({ pid: 3, status: "busy", needs: ["aws-login:prod"] }),
    ];
    const without = sidebarSessionsView({
      capability: true,
      snapshot: snapshot({ sessions }),
      now: NOW,
    });
    expect(without?.rows.map((row) => row.pid)).toEqual([1, 3, 2]);
    expect(without?.attentionCount).toBe(2);
    expect(without?.actions).toEqual({ setMode: false, show: false, nudge: false });

    const withVerbs = sidebarSessionsView({
      capability: true,
      snapshot: snapshot({
        sessions,
        commands: [
          command("session-mode"),
          command("show", ["popout|settings|session <pid|name>"]),
          command("nudge", ["<pid|name>"]),
        ],
      }),
      now: NOW,
    });
    expect(withVerbs?.actions).toEqual({ setMode: true, show: true, nudge: true });
  });
});

describe("sessionRowDetail", () => {
  it("shows the folder for a named row, the state for a folder-titled one, then account and age", () => {
    const [named] = sidebarSessionsView({
      capability: true,
      snapshot: snapshot({
        sessions: [session({ name: "peon", account: "death4", startedAt: "2026-09-10T11:20:00Z" })],
      }),
      now: NOW,
    })!.rows;
    expect(sessionRowDetail(named!)).toBe("proj · death4 · 40m");
    const [bare] = sidebarSessionsView({
      capability: true,
      snapshot: snapshot({ sessions: [session({ status: "busy" })] }),
      now: NOW,
    })!.rows;
    expect(sessionRowDetail(bare!)).toBe("working");
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
