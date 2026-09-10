import { describe, expect, it } from "vite-plus/test";

import {
  EMPTY_PROFILE_DRAFT,
  parseInfinitusProfiles,
  profileCommandsSupported,
  profileDraft,
  profileSetArgs,
  profileSummary,
} from "./profiles.logic";

const command = (name: string) => ({
  name,
  args: [],
  options: [],
  effect: "write" as const,
  summary: "",
  replyShape: "",
});

describe("profileCommandsSupported", () => {
  it("needs all three commands the pane calls", () => {
    expect(
      profileCommandsSupported(["profiles", "profile-set", "profile-remove"].map(command)),
    ).toBe(true);
    expect(profileCommandsSupported(["profiles", "profile-set"].map(command))).toBe(false);
    expect(profileCommandsSupported([])).toBe(false);
  });
});

describe("parseInfinitusProfiles", () => {
  it("reads the reply and keeps the fields a profile filled", () => {
    const profiles = parseInfinitusProfiles({
      profiles: [{ name: "review", cwd: "~/code/app", allowTools: ["Edit"] }],
    });

    expect(profiles).toEqual([{ name: "review", cwd: "~/code/app", allowTools: ["Edit"] }]);
  });

  it("answers null for a reply this build cannot read", () => {
    expect(parseInfinitusProfiles({ profiles: [{ cwd: "~/code/app" }] })).toBeNull();
    expect(parseInfinitusProfiles(undefined)).toBeNull();
  });
});

describe("profileSetArgs", () => {
  it("keys the options without dashes and leaves out what was cleared", () => {
    expect(
      profileSetArgs({
        ...EMPTY_PROFILE_DRAFT,
        name: " review ",
        cwd: "~/code/app",
        permissionMode: "acceptEdits",
        allowTools: "Edit, Bash git",
      }),
    ).toEqual({
      command: "profile-set",
      args: ["review"],
      options: { cwd: "~/code/app", mode: "acceptEdits", allow: "Edit, Bash git" },
    });
  });
});

describe("profileDraft and profileSummary", () => {
  it("round-trips the allow-list through the one string the command takes", () => {
    expect(profileDraft({ name: "review", allowTools: ["Edit", "Bash git"] }).allowTools).toBe(
      "Edit, Bash git",
    );
    expect(profileDraft({ name: "scratch" })).toEqual({ ...EMPTY_PROFILE_DRAFT, name: "scratch" });
  });

  it("summarises only the fields a profile fills", () => {
    expect(profileSummary({ name: "review", cwd: "~/code/app", engine: "claude" })).toBe(
      "~/code/app · claude",
    );
    expect(profileSummary({ name: "scratch" })).toBe("");
  });
});
