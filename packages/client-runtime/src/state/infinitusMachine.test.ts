import { describe, expect, it } from "vite-plus/test";

import {
  bytesText,
  decodeMachineReply,
  hookGroups,
  idleHours,
  isHeavyHook,
  ownerKindLabel,
  type HookGroup,
  type MachineHook,
} from "./infinitusMachine.ts";

const hook = (
  owner: string,
  event: string,
  command: string,
  spawnsPerHour: number,
  live: Partial<MachineHook["live"]> = {},
): MachineHook => ({
  registration: { event, command, ownerKind: "plugin", owner },
  spawnsPerHour,
  live: { instances: 0, helpers: 0, oldestSeconds: 0, uninterruptible: 0, ...live },
});

const report = {
  sample: { at: "2026-09-11T03:00:40Z", cores: 16, load1: 15.57, load5: 20.97, tempEntries: 43889 },
  hooks: [
    {
      registration: {
        event: "PreToolUse",
        matcher: "Bash",
        command: "python3 guard.py",
        timeout: 10,
        source: { plugin: { _0: "ecc" } },
        ownerKind: "plugin",
        owner: "ecc",
      },
      spawnsPerHour: 360,
      live: { instances: 0, helpers: 0, oldestSeconds: 0, uninterruptible: 0 },
    },
  ],
  runaways: [],
  residue: { staleSockets: 2, transcriptsBytes: 1024 },
  sessions: [{ pid: 12, name: "limitless", cwd: "/x", rssMB: 300, ageSeconds: 60 }],
  warnings: ["temp directory holds 43889 entries"],
};

describe("decodeMachineReply", () => {
  it("reads a report, ignoring the fields the page does not render", () => {
    const reply = decodeMachineReply(report);
    expect(reply?._tag).toBe("report");
    if (reply?._tag !== "report") return;
    expect(reply.report.sample.load1).toBe(15.57);
    expect(reply.report.hooks[0]?.registration.owner).toBe("ecc");
    expect(reply.report.residue.staleSockets).toBe(2);
    expect(reply.report.sessions[0]?.lastActivityAt).toBeUndefined();
  });

  it("tells the sampling marker from garbage", () => {
    expect(decodeMachineReply({ sampling: true })).toEqual({ _tag: "sampling" });
    expect(decodeMachineReply({ sampling: false })).toBeNull();
    expect(decodeMachineReply("nope")).toBeNull();
    expect(decodeMachineReply({ ...report, hooks: "many" })).toBeNull();
  });
});

describe("hookGroups", () => {
  it("folds an owner's hooks and puts the ones that need a look first", () => {
    const groups = hookGroups([
      hook("quiet", "Stop", "echo ok", 24),
      hook("busy", "PreToolUse", "python3 a.py", 5400),
      hook("busy", "PostToolUse", "python3 b.py", 240, { helpers: 1 }),
      hook("busy", "PreToolUse", "python3 c.py", 60),
      hook("live", "Stop", "node x.js", 10, { instances: 3, oldestSeconds: 120 }),
      hook("wedged", "Stop", "curl x", 10, { instances: 1, uninterruptible: 1 }),
    ]);
    expect(groups.map((group: HookGroup) => group.owner)).toEqual([
      "wedged",
      "live",
      "busy",
      "quiet",
    ]);
    const busy = groups[2];
    expect(busy).toMatchObject({
      registrations: 3,
      risky: true,
      helpers: 1,
      spawnsPerHour: 5700,
      events: ["PreToolUse", "PostToolUse"],
      stuck: 0,
    });
    expect(groups[0]?.stuck).toBe(1);
    expect(groups[1]?.oldestSeconds).toBe(120);
    expect(groups[3]?.risky).toBe(false);
  });

  it("counts a hook as risky only when it is heavy and busy", () => {
    expect(isHeavyHook('node"x"')).toBe(true);
    expect(isHeavyHook("osascript -e x")).toBe(true);
    expect(isHeavyHook("echo hi")).toBe(false);
    expect(hookGroups([hook("a", "Stop", "echo hi", 5400)])[0]?.risky).toBe(false);
    expect(hookGroups([hook("a", "Stop", "python3 x", 99)])[0]?.risky).toBe(false);
    expect(hookGroups([hook("a", "Stop", "python3 x", 100)])[0]?.risky).toBe(true);
  });
});

describe("formatting", () => {
  it("labels owner kinds and sizes", () => {
    expect(ownerKindLabel("handInstalled")).toBe("Hand-installed");
    expect(ownerKindLabel("cask")).toBe("Cask");
    expect(bytesText(512_000)).toBe("500 KB");
    expect(bytesText(2_621_440)).toBe("2.5 MB");
    expect(bytesText(3 * 1_073_741_824)).toBe("3.0 GB");
  });

  it("counts idle hours from the last activity", () => {
    const now = Date.parse("2026-09-11T03:00:00Z");
    const session = { pid: 1, name: "x", cwd: "/", lastActivityAt: "2026-09-10T23:30:00Z" };
    expect(idleHours(session, now)).toBe(3);
    expect(idleHours({ pid: 1, name: "x", cwd: "/" }, now)).toBeNull();
    expect(idleHours({ ...session, lastActivityAt: "soon" }, now)).toBeNull();
  });
});
