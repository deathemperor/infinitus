import { EnvironmentId } from "@infinitus/contracts";
import { InfinitusTeamError } from "@infinitus/client-runtime/relay/infinitusTeam";
import { describe, expect, it } from "vite-plus/test";

import {
  parseTeamExclusions,
  teamErrorMessage,
  teamExcludeInput,
  teamExclusionSlug,
  teamExclusionsSupported,
  teamGrantDraft,
  teamMemberName,
} from "./team.logic";

const command = (name: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
});

describe("team.logic (#1592)", () => {
  it("reads the Mac's private projects", () => {
    expect(teamExclusionsSupported([command("team-status")])).toBe(false);
    expect(teamExclusionsSupported([command("team-exclusions")])).toBe(true);
    expect(parseTeamExclusions({ projects: ["/Users/loc/secret"] })).toEqual(["/Users/loc/secret"]);
    expect(parseTeamExclusions({ nope: 1 })).toBeNull();
    expect(teamExcludeInput("secret", true)).toEqual({
      command: "team-exclude",
      args: ["add", "secret"],
      options: {},
    });
    expect(teamExclusionSlug("  secret-lab ")).toBe("secret-lab");
    expect(teamExclusionSlug("has space")).toBeNull();
    expect(teamMemberName(" Loc ")).toBe("Loc");
    expect(teamMemberName("x".repeat(65))).toBeNull();
  });

  it("drafts a grant", () => {
    const environmentId = EnvironmentId.make("env-1");
    expect(
      teamGrantDraft({
        environmentId,
        audience: "user-2",
        capabilities: ["view", "send", "bogus"],
        threads: "t-1, t-2,",
        preauthorized: ["interrupt", "send"],
      }),
    ).toEqual({
      environmentId,
      audience: ["user-2"],
      threads: ["t-1", "t-2"],
      capabilities: ["view", "send"],
      preauthorized: ["send"],
    });
    expect(
      teamGrantDraft({
        environmentId,
        audience: "team",
        capabilities: ["new"],
        threads: "",
        preauthorized: [],
      }),
    ).toEqual({ environmentId, audience: "team", threads: "all", capabilities: ["new"] });
    expect(
      teamGrantDraft({ environmentId, audience: "team", capabilities: [], threads: "", preauthorized: [] }),
    ).toBeNull();
  });

  it("shows the relay's reason verbatim and a trace id on a failure", () => {
    expect(teamErrorMessage(new InfinitusTeamError("refused", "Only a leader can do that."))).toBe(
      "Only a leader can do that.",
    );
    expect(teamErrorMessage(new InfinitusTeamError("failed", "Relay is down.", "trace-1"))).toBe(
      "Relay is down. Trace ID: trace-1",
    );
    expect(teamErrorMessage(new InfinitusTeamError("signedOut", "Sign in first."))).toBe("Sign in first.");
    expect(teamErrorMessage(new Error("boom"))).toBe("boom");
    expect(teamErrorMessage(undefined)).toBe("Something went wrong.");
  });
});
