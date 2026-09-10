import { EnvironmentId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  pusherMac,
  registrationBody,
  registrationCommand,
  shouldSendToken,
  TOKEN_RESEND_INTERVAL_MS,
} from "./liveActivity.logic";

const studio = { environmentId: EnvironmentId.make("mac-1"), label: "Studio", connected: true };
const mini = { environmentId: EnvironmentId.make("mac-2"), label: "Mini", connected: false };

describe("pusherMac", () => {
  it("honours the preference while that Mac is paired, else takes the first", () => {
    expect(pusherMac("mac-2", [studio, mini])).toBe(mini);
    expect(pusherMac("gone", [studio, mini])).toBe(studio);
    expect(pusherMac(undefined, [studio, mini])).toBe(studio);
    expect(pusherMac("mac-1", [])).toBeNull();
  });
});

describe("registrationBody / registrationCommand", () => {
  const body = registrationBody({
    kind: "working-start",
    token: "8f3a",
    deviceId: "dev-1",
    deviceName: "Loc's iPhone",
    environmentId: studio.environmentId,
    sandbox: true,
    now: new Date("2026-09-10T10:00:00Z"),
  });

  it("files the Mac under its environment id and asks for the expo envelope", () => {
    expect(body).toEqual({
      kind: "working-start",
      token: "8f3a",
      deviceId: "dev-1",
      deviceName: "Loc's iPhone",
      environment: "sandbox",
      themeID: null,
      registeredAt: "2026-09-10T10:00:00.000Z",
      macId: "mac-1",
      layout: "expo",
    });
    expect(registrationBody({ ...bodyInput(), sandbox: false }).environment).toBe("production");
  });

  it("rides the activities-token verb's --body option as one JSON string", () => {
    const command = registrationCommand(body);
    expect(command.command).toBe("activities-token");
    expect(command.args).toEqual([]);
    expect(JSON.parse(command.options.body ?? "")).toEqual(body);
  });

  function bodyInput() {
    return {
      kind: "working" as const,
      token: "t",
      deviceId: "d",
      deviceName: "n",
      environmentId: studio.environmentId,
      sandbox: true,
      now: new Date(0),
    };
  }
});

describe("shouldSendToken", () => {
  it("sends a new token at once, a repeat only after the interval", () => {
    const sent = new Map([["working" as const, { token: "a", at: 1_000 }]]);
    expect(shouldSendToken(sent, "working", "b", 1_001)).toBe(true);
    expect(shouldSendToken(sent, "revival", "a", 1_001)).toBe(true);
    expect(shouldSendToken(sent, "working", "a", 1_001)).toBe(false);
    expect(shouldSendToken(sent, "working", "a", 1_000 + TOKEN_RESEND_INTERVAL_MS)).toBe(true);
  });
});
