import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  asksForSession,
  parsePermissionAsks,
  permissionAskActions,
  permissionAskLabel,
  permissionDecideCommandArgs,
} from "./permissionAsks.logic";

function command(name: string): InfinitusManifestCommand {
  return { name, args: [], options: [], effect: "read", summary: "", replyShape: "" };
}

const ROW = {
  id: "a1",
  pid: 42,
  sessionId: "s1",
  tool: "Bash",
  input: "git push origin main",
  askedAt: "2026-09-12T10:00:00Z",
  expiresAt: "2026-09-12T10:01:00Z",
};

describe("permission asks (#79 item 3)", () => {
  it("offers the card only when the manifest lists its verbs", () => {
    expect(permissionAskActions([])).toEqual({ pending: false, decide: false });
    expect(permissionAskActions([command("permission-pending")])).toEqual({
      pending: true,
      decide: false,
    });
    expect(
      permissionAskActions([command("permission-pending"), command("permission-decide")]),
    ).toEqual({ pending: true, decide: true });
  });

  it("reads the pending reply defensively", () => {
    expect(parsePermissionAsks([ROW, { id: "no-session" }, "junk", null])).toEqual([
      {
        id: "a1",
        pid: 42,
        sessionId: "s1",
        tool: "Bash",
        input: "git push origin main",
        expiresAt: Date.parse("2026-09-12T10:01:00Z"),
      },
    ]);
    expect(parsePermissionAsks({ not: "a list" })).toEqual([]);
    const bare = parsePermissionAsks([{ id: "b", sessionId: "s", tool: "Edit", pid: null }]);
    expect(bare[0]?.input).toBe("");
    expect(bare[0]?.expiresAt).toBeNull();
  });

  it("matches an ask to its row by pid, else by session id", () => {
    const asks = parsePermissionAsks([ROW, { ...ROW, id: "a2", pid: null, sessionId: "s2" }]);
    expect(asksForSession(asks, { pid: 42, sessionId: "other" }).map((ask) => ask.id)).toEqual([
      "a1",
    ]);
    expect(asksForSession(asks, { pid: 7, sessionId: "s2" }).map((ask) => ask.id)).toEqual(["a2"]);
    expect(asksForSession(asks, { pid: 7, sessionId: null })).toEqual([]);
  });

  it("decides by id and labels the tool with its input", () => {
    const [ask] = parsePermissionAsks([ROW]);
    expect(ask).toBeDefined();
    if (ask === undefined) return;
    expect(permissionDecideCommandArgs(ask, "deny")).toEqual({
      command: "permission-decide",
      args: ["a1", "deny"],
    });
    expect(permissionAskLabel(ask)).toBe("Bash · git push origin main");
    expect(permissionAskLabel({ ...ask, input: "" })).toBe("Bash");
  });
});
