import type {
  InfinitusManifestCommand,
  InfinitusSession,
  InfinitusSnapshot,
} from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  formatAge,
  needLabel,
  nudgeCommandArgs,
  nudgeOutcome,
  sessionActions,
  sessionModeCommandArgs,
  sessionRow,
  sessionRows,
  sessionState,
  showSessionCommandArgs,
} from "./infinitusSessions.ts";

const NOW = Date.parse("2026-09-10T12:00:00Z");

function session(overrides: Partial<InfinitusSession> = {}): InfinitusSession {
  return { pid: 100, cwd: "/Users/me/work/limitless", kind: "interactive", ...overrides };
}

function snapshot(sessions: InfinitusSession[]): InfinitusSnapshot {
  return { available: true, fleets: [], sessions, commands: [] };
}

function command(name: string, args: string[] = []): InfinitusManifestCommand {
  return { name, args, options: [], effect: "write", summary: "", replyShape: "" };
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
    expect(sessionRow(session({ name: "peon", status: "busy" }), NOW)).toEqual({
      pid: 100,
      sessionId: null,
      title: "peon",
      folder: "limitless",
      cwd: "/Users/me/work/limitless",
      state: "working",
      stateLabel: "working",
      needsAttention: false,
      account: null,
      startedAt: null,
      age: null,
      needs: [],
      kind: "interactive",
      permissionMode: "supervised",
    });
    expect(sessionRow(session({ name: null, cwd: "/tmp/proj/" }), NOW).title).toBe("proj");
  });

  it("reads a null or unknown permission mode as supervised", () => {
    expect(sessionRow(session({ permissionMode: null }), NOW).permissionMode).toBe("supervised");
    expect(sessionRow(session({ permissionMode: "plan" }), NOW).permissionMode).toBe("supervised");
    expect(sessionRow(session({ permissionMode: "bypassPermissions" }), NOW).permissionMode).toBe(
      "bypassPermissions",
    );
  });

  it("carries the #612 fields: id, account, age from startedAt, needs as chips", () => {
    const row = sessionRow(
      session({
        sessionId: "e2e-aws",
        account: "death4",
        startedAt: "2026-09-10T09:30:00Z",
        needs: ["aws-login:prod", "gcloud-login:me@x.dev", "totp"],
        status: "idle",
      }),
      NOW,
    );
    expect(row.sessionId).toBe("e2e-aws");
    expect(row.account).toBe("death4");
    expect(row.startedAt).toBe(Date.parse("2026-09-10T09:30:00Z"));
    expect(row.age).toBe("2h");
    expect(row.needs).toEqual([
      "needs AWS sign-in (prod)",
      "needs gcloud sign-in (me@x.dev)",
      "needs sign-in",
    ]);
    expect(row.needsAttention).toBe(true);
    expect(sessionRow(session({ startedAt: "garbage" }), NOW).age).toBeNull();
    expect(sessionRow(session({ startedAt: null, account: null }), NOW).account).toBeNull();
  });
});

describe("formatAge / needLabel", () => {
  it("is minutes under an hour, hours under two days, then days", () => {
    expect(formatAge(NOW - 5 * 60_000, NOW)).toBe("5m");
    expect(formatAge(NOW - 90 * 60_000, NOW)).toBe("1h");
    expect(formatAge(NOW - 47 * 3_600_000, NOW)).toBe("47h");
    expect(formatAge(NOW - 3 * 86_400_000, NOW)).toBe("3d");
    expect(formatAge(NOW + 60_000, NOW)).toBe("0m");
  });

  it("names the provider and target of a need", () => {
    expect(needLabel("aws-login:prod")).toBe("needs AWS sign-in (prod)");
    expect(needLabel("aws-login")).toBe("needs AWS sign-in");
    expect(needLabel("gcloud-login:a@b.c")).toBe("needs gcloud sign-in (a@b.c)");
    expect(needLabel("something-else:x")).toBe("needs sign-in");
  });
});

describe("sessionRows", () => {
  it("puts sessions needing a person first (waiting, or a pending sign-in), then by state and title", () => {
    const rows = sessionRows(
      snapshot([
        session({ pid: 1, name: "zeta", status: "idle" }),
        session({ pid: 2, name: "beta", status: "busy" }),
        session({ pid: 3, name: "alpha", status: "waiting" }),
        session({ pid: 4, name: "gamma", status: "busy" }),
        session({ pid: 5, name: "omega", status: null }),
        session({ pid: 6, name: "delta", status: "busy", needs: ["aws-login:prod"] }),
      ]),
      NOW,
    );
    expect(rows.map((row) => row.title)).toEqual([
      "alpha",
      "delta",
      "beta",
      "gamma",
      "zeta",
      "omega",
    ]);
  });
});

describe("sessionActions", () => {
  it("offers each verb only when the manifest lists it, and show only with a session arg", () => {
    expect(sessionActions([])).toEqual({ setMode: false, show: false, nudge: false });
    expect(
      sessionActions([
        command("session-mode", ["<pid|name>", "<supervised|acceptEdits|bypassPermissions>"]),
        command("show", [
          "popout|settings|wall|workspace [sidebar|thread|composer|draft|switcher]",
        ]),
      ]),
    ).toEqual({ setMode: true, show: false, nudge: false });
    expect(
      sessionActions([
        command("show", [
          "popout|settings|wall|workspace [sidebar|thread|composer|draft|switcher]|session <pid|name>",
        ]),
        command("nudge", ["<pid|name>"]),
      ]),
    ).toEqual({ setMode: false, show: true, nudge: true });
  });
});

describe("command args", () => {
  it("address the session by pid", () => {
    const row = sessionRow(session({ pid: 4321, name: "dup" }), NOW);
    expect(sessionModeCommandArgs(row, "acceptEdits")).toEqual({
      command: "session-mode",
      args: ["4321", "acceptEdits"],
    });
    expect(showSessionCommandArgs(row)).toEqual({ command: "show", args: ["session", "4321"] });
    expect(nudgeCommandArgs(row)).toEqual({ command: "nudge", args: ["4321"] });
  });
});

describe("nudgeOutcome", () => {
  it("reads nudged and the reason from the reply, and nothing from junk", () => {
    expect(nudgeOutcome({ pid: 1, nudged: true, channel: "peer", reason: null })).toEqual({
      nudged: true,
      reason: null,
    });
    expect(nudgeOutcome({ pid: 1, nudged: false, reason: "not resumable: no limit stop" })).toEqual(
      { nudged: false, reason: "not resumable: no limit stop" },
    );
    expect(nudgeOutcome(undefined)).toEqual({ nudged: false, reason: null });
    expect(nudgeOutcome("x")).toEqual({ nudged: false, reason: null });
  });
});
