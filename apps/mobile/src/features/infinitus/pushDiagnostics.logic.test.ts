import { describe, expect, it } from "vite-plus/test";

import {
  agentActivityPushSummary,
  EMPTY_AGENT_ACTIVITY_PUSH_STATE,
  withRegistration,
  withWatching,
} from "./pushDiagnostics.logic";

const WATCHING = withWatching(EMPTY_AGENT_ACTIVITY_PUSH_STATE, new Date("2026-09-14T02:11:00Z"));
const registered = (at: string) => ({ outcome: "registered", at, detail: null }) as const;

describe("agentActivityPushSummary", () => {
  it("says the bridge is not running before it has attached", () => {
    expect(agentActivityPushSummary(EMPTY_AGENT_ACTIVITY_PUSH_STATE).value).toBe("Not running");
  });

  it("separates a bridge that is watching from one that never started", () => {
    const summary = agentActivityPushSummary(WATCHING);
    expect(summary.value).toBe("No token yet");
    expect(summary.explanation).toContain("Live Activities");
  });

  it("reports a start token the Mac took", () => {
    const state = withRegistration(
      WATCHING,
      "agent-activity-start",
      registered("2026-09-14T02:11:14.000Z"),
    );
    expect(agentActivityPushSummary(state).value).toBe("Registered");
  });

  it("distinguishes a live card's token from the start token iOS never vended", () => {
    const state = withRegistration(
      WATCHING,
      "agent-activity",
      registered("2026-09-14T02:12:00.000Z"),
    );
    expect(agentActivityPushSummary(state).value).toBe("Card token only");
  });

  it("gives a refusal precedence over a registration, in the Mac's own words", () => {
    const state = withRegistration(
      withRegistration(WATCHING, "agent-activity-start", registered("2026-09-14T02:11:14.000Z")),
      "agent-activity",
      { outcome: "refused", at: "2026-09-14T02:13:00.000Z", detail: "unknown verb" },
    );
    const summary = agentActivityPushSummary(state);
    expect(summary.value).toBe("Refused");
    expect(summary.explanation).toContain("unknown verb");
    expect(summary.explanation).toContain("card token");
  });

  it("reports the newer of two refusals", () => {
    const state = withRegistration(
      withRegistration(WATCHING, "agent-activity", {
        outcome: "refused",
        at: "2026-09-14T02:12:00.000Z",
        detail: "older",
      }),
      "agent-activity-start",
      { outcome: "refused", at: "2026-09-14T02:14:00.000Z", detail: "newer" },
    );
    expect(agentActivityPushSummary(state).explanation).toContain("newer");
  });

  it("never says the Mac refused a token it could not be handed", () => {
    const state = withRegistration(WATCHING, "agent-activity-start", {
      outcome: "unreachable",
      at: "2026-09-14T02:11:20.000Z",
      detail: "HyperNovae is not connected.",
    });
    const summary = agentActivityPushSummary(state);
    expect(summary.value).toBe("Mac unreachable");
    expect(summary.explanation).toContain("could not reach the Mac");
    expect(summary.explanation).toContain("HyperNovae is not connected.");
    expect(summary.explanation).not.toContain("refused this phone");
  });

  it("goes back to not running when the bridge lets its listeners go", () => {
    const state = withWatching(
      withRegistration(WATCHING, "agent-activity-start", registered("2026-09-14T02:11:14.000Z")),
      null,
    );
    expect(agentActivityPushSummary(state).value).toBe("Not running");
  });
});

describe("agentActivityPushSummary — withdrawn card token (#1265)", () => {
  it("stays Registered and says the last card's token was taken back", () => {
    const state = withRegistration(
      withRegistration(WATCHING, "agent-activity-start", registered("2026-09-14T02:12:00Z")),
      "agent-activity",
      { outcome: "withdrawn", at: "2026-09-14T03:00:00Z", detail: null },
    );
    const summary = agentActivityPushSummary(state);
    expect(summary.value).toBe("Registered");
    expect(summary.explanation).toContain("withdrawn");
    expect(summary.explanation).toContain("start token");
  });
});
