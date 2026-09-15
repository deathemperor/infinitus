import { describe, expect, it } from "vite-plus/test";

import {
  agentActivityPushSummary,
  EMPTY_AGENT_ACTIVITY_PUSH_STATE,
  withBackgroundCard,
  withRegistration,
  withSwitchOff,
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

describe("agentActivityPushSummary — the switch off (#1265)", () => {
  const off = withWatching(WATCHING, null);

  it("reads what the withdrawal did, and that an unreachable one is retried", () => {
    expect(
      agentActivityPushSummary(
        withSwitchOff(off, { outcome: "withdrawn", at: "2026-09-15T04:00:00Z", detail: null }),
      ).value,
    ).toBe("Off, withdrawn");
    const unreachable = agentActivityPushSummary(
      withSwitchOff(off, {
        outcome: "unreachable",
        at: "2026-09-15T04:00:00Z",
        detail: "mac-1 is not connected",
      }),
    );
    expect(unreachable.value).toBe("Off, Mac unreachable");
    expect(unreachable.explanation).toContain("foreground");
    expect(
      agentActivityPushSummary(
        withSwitchOff(off, { outcome: "refused", at: "2026-09-15T04:00:00Z", detail: null }),
      ).value,
    ).toBe("Off, refused");
  });

  it("forgets the switch-off once the bridge watches again", () => {
    const state = withWatching(
      withSwitchOff(off, { outcome: "withdrawn", at: "2026-09-15T04:00:00Z", detail: null }),
      new Date("2026-09-15T04:01:00Z"),
    );
    expect(state.switchOff).toBeNull();
    expect(agentActivityPushSummary(state).value).toBe("No token yet");
  });
});

describe("agentActivityPushSummary — a card started in the background (#1277)", () => {
  const registeredStart = withRegistration(
    WATCHING,
    "agent-activity-start",
    registered("2026-09-15T06:17:00Z"),
  );

  it("says how long the token took to reach the Mac", () => {
    const summary = agentActivityPushSummary(
      withBackgroundCard(registeredStart, {
        startedAt: "2026-09-15T06:17:34Z",
        outcome: "sent",
        elapsedMs: 4_200,
      }),
    );
    expect(summary.value).toBe("Registered");
    expect(summary.explanation).toContain("started in the background");
    expect(summary.explanation).toContain("reached the Mac 4 s later");
  });

  it("says the Mac was unreachable inside the window, and that the token waits for the app", () => {
    const summary = agentActivityPushSummary(
      withBackgroundCard(registeredStart, {
        startedAt: "2026-09-15T06:17:34Z",
        outcome: "unreachable",
        elapsedMs: 9_800,
      }),
    );
    expect(summary.explanation).toContain("unreachable 10 s later");
    expect(summary.explanation).toContain("next opened");
  });

  it("adds nothing while the bridge is not running", () => {
    const state = withBackgroundCard(EMPTY_AGENT_ACTIVITY_PUSH_STATE, {
      startedAt: "2026-09-15T06:17:34Z",
      outcome: "sent",
      elapsedMs: 1_000,
    });
    expect(agentActivityPushSummary(state).explanation).not.toContain("background");
  });
});
