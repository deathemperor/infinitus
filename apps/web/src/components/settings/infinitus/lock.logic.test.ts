import { describe, expect, it } from "vite-plus/test";

import {
  lockCommandInput,
  lockCommandsSupported,
  lockOffRefusalTeams,
  parseLockStatus,
  RELOCK_CHOICES,
  relockChoiceFor,
} from "./lock.logic";

const command = (name: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
});

describe("lock.logic (#747)", () => {
  it("needs all three lock verbs in the manifest", () => {
    expect(lockCommandsSupported(["lock-status", "lock", "unlock"].map(command))).toBe(true);
    expect(lockCommandsSupported(["lock-status", "lock"].map(command))).toBe(false);
  });

  it("reads the lock-status reply and refuses another shape", () => {
    expect(parseLockStatus({ enabled: true, locked: false, relock: "5 min" })).toEqual({
      enabled: true,
      locked: false,
      relock: "5 min",
    });
    expect(parseLockStatus({ enabled: "yes" })).toBeNull();
    expect(parseLockStatus(undefined)).toBeNull();
  });

  it("maps every native relock label to a choice", () => {
    for (const choice of RELOCK_CHOICES) expect(relockChoiceFor(choice.native)).toBe(choice);
    expect(relockChoiceFor("2 h")).toBeNull();
  });

  it("builds the verbs the Mac expects", () => {
    expect(lockCommandInput({ type: "status" })).toEqual({
      command: "lock-status",
      args: [],
      options: {},
    });
    expect(lockCommandInput({ type: "on" })).toEqual({
      command: "lock",
      args: ["on"],
      options: {},
    });
    expect(lockCommandInput({ type: "off", force: false })).toEqual({
      command: "lock",
      args: ["off"],
      options: {},
    });
    expect(lockCommandInput({ type: "off", force: true })).toEqual({
      command: "lock",
      args: ["off"],
      options: { yes: "true" },
    });
    expect(lockCommandInput({ type: "relock", arg: "sleep" })).toEqual({
      command: "lock",
      args: ["relock", "sleep"],
      options: {},
    });
    expect(lockCommandInput({ type: "unlock" })).toEqual({
      command: "unlock",
      args: [],
      options: {},
    });
  });

  it("reads the team names out of a refused lock off", () => {
    expect(
      lockOffRefusalTeams("this Mac is in Alpha, Beta; lock off --yes turns the lock off anyway"),
    ).toEqual(["Alpha", "Beta"]);
    expect(lockOffRefusalTeams("the unlock prompt was cancelled")).toBeNull();
  });
});
