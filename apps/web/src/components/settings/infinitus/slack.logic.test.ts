import { DEFAULT_SERVER_SETTINGS } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  parseAllowedUserIds,
  slackStatusLine,
  slackTokenPatch,
  slackTokenSet,
} from "./slack.logic";

const base = DEFAULT_SERVER_SETTINGS.infinitusSlack;

describe("Slack settings logic (#574)", () => {
  it("reads a token as set from the server's marker, never its value", () => {
    expect(slackTokenSet("")).toBe(false);
    expect(slackTokenSet("••••••")).toBe(true);
    expect(slackTokenPatch("  ")).toBeNull();
    expect(slackTokenPatch(" xapp-1 ")).toBe("xapp-1");
  });

  it("splits member ids on commas, spaces and lines and dedupes", () => {
    expect(parseAllowedUserIds("U1, U2\nU1  U3,")).toEqual(["U1", "U2", "U3"]);
    expect(parseAllowedUserIds("")).toEqual([]);
  });

  it("says what is missing before the bridge is live", () => {
    expect(slackStatusLine(base)).toBe("Off.");
    expect(slackStatusLine({ ...base, enabled: true })).toBe(
      "Inert until the app token, the bot token, an allowed member are set.",
    );
    expect(slackStatusLine({ ...base, enabled: true, appToken: "•", botToken: "•" })).toBe(
      "Inert until an allowed member is set.",
    );
    expect(
      slackStatusLine({
        ...base,
        enabled: true,
        appToken: "•",
        botToken: "•",
        allowedUserIds: ["U1"],
      }),
    ).toBe("On for 1 member.");
  });
});
