import { InfinitusTeamError } from "@infinitus/client-runtime/relay/infinitusTeam";
import { describe, expect, it } from "vite-plus/test";

import { teamErrorMessage, teamJoinLinkCode, teamMemberName, teamRoleLabel } from "./team.logic";

describe("teamJoinLinkCode", () => {
  it("takes the fragment of the site's /join as the token", () => {
    expect(teamJoinLinkCode("https://infinitus.run/join#abc-123")).toBe("abc-123");
    expect(teamJoinLinkCode(" https://infinitus.run/join/#abc%2B1 ")).toBe("abc+1");
  });

  it("refuses any other host, path or scheme, and an empty fragment", () => {
    expect(teamJoinLinkCode("https://example.com/join#abc")).toBeNull();
    expect(teamJoinLinkCode("http://infinitus.run/join#abc")).toBeNull();
    expect(teamJoinLinkCode("https://infinitus.run/pair#abc")).toBeNull();
    expect(teamJoinLinkCode("https://infinitus.run/join")).toBeNull();
    expect(teamJoinLinkCode("https://infinitus.run/join#")).toBeNull();
    expect(teamJoinLinkCode("not a url")).toBeNull();
  });
});

describe("the roster name and the error line", () => {
  it("trims the name and refuses blank or over 64", () => {
    expect(teamMemberName("  Ann ")).toBe("Ann");
    expect(teamMemberName("   ")).toBeNull();
    expect(teamMemberName("x".repeat(65))).toBeNull();
    expect(teamRoleLabel("leader")).toBe("Leader");
  });

  it("shows the relay's sentence, a trace id on a failure, a plain line otherwise", () => {
    expect(
      teamErrorMessage(new InfinitusTeamError("refused", "The invite has expired.", null)),
    ).toBe("The invite has expired.");
    expect(teamErrorMessage(new InfinitusTeamError("failed", "The relay failed.", "tr-1"))).toBe(
      "The relay failed. Trace ID: tr-1",
    );
    expect(teamErrorMessage(new Error("offline"))).toBe("offline");
    expect(teamErrorMessage("?")).toBe("The request failed.");
  });
});
