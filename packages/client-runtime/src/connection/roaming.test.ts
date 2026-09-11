import { EnvironmentId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { BearerConnectionProfile } from "./catalog.ts";
import { ConnectionBlockedError, ConnectionTransientError } from "./model.ts";
import { bearerHostOrder, learnedBearerProfile, roamsPast } from "./roaming.ts";

const LAN = "http://192.168.100.61:3773";
const TUNNEL = "https://code.infinitus.run";

const profile = (over: Partial<ConstructorParameters<typeof BearerConnectionProfile>[0]> = {}) =>
  new BearerConnectionProfile({
    connectionId: "bearer:env-1",
    environmentId: EnvironmentId.make("env-1"),
    label: "Mac",
    httpBaseUrl: LAN,
    wsBaseUrl: "ws://192.168.100.61:3773",
    ...over,
  });

describe("bearerHostOrder", () => {
  it("tries the host that worked last, then the paired one, then the alternates, once each", () => {
    expect(bearerHostOrder(profile())).toEqual([LAN]);
    expect(bearerHostOrder(profile({ alternateHttpBaseUrls: [TUNNEL] }))).toEqual([LAN, TUNNEL]);
    expect(
      bearerHostOrder(profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: TUNNEL })),
    ).toEqual([TUNNEL, LAN]);
    expect(
      bearerHostOrder(profile({ alternateHttpBaseUrls: [TUNNEL, LAN], lastGoodHttpBaseUrl: LAN })),
    ).toEqual([LAN, TUNNEL]);
  });
});

describe("roamsPast", () => {
  it("walks past a host that could not be reached, never one that refused", () => {
    expect(roamsPast(new ConnectionTransientError({ reason: "network", detail: "x" }))).toBe(true);
    expect(roamsPast(new ConnectionTransientError({ reason: "timeout", detail: "x" }))).toBe(true);
    expect(
      roamsPast(new ConnectionTransientError({ reason: "remote-unavailable", detail: "x" })),
    ).toBe(false);
    expect(roamsPast(new ConnectionBlockedError({ reason: "authentication", detail: "x" }))).toBe(
      false,
    );
  });
});

describe("learnedBearerProfile", () => {
  it("learns the tunnel from a later LAN connect when the pairing had none", () => {
    const paired = profile();
    const learned = learnedBearerProfile(paired, LAN, { alternateHttpBaseUrls: [TUNNEL] });
    expect(learned).not.toBeNull();
    expect(learned?.alternateHttpBaseUrls).toEqual([TUNNEL]);
    expect(learned?.lastGoodHttpBaseUrl).toBe(LAN);
    expect(learned?.httpBaseUrl).toBe(LAN);
  });

  it("remembers a roam to the tunnel and the way back", () => {
    const home = profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: LAN });
    const away = learnedBearerProfile(home, TUNNEL, { alternateHttpBaseUrls: [TUNNEL] });
    expect(away?.lastGoodHttpBaseUrl).toBe(TUNNEL);
    expect(away?.alternateHttpBaseUrls).toEqual([TUNNEL]);
    const back = learnedBearerProfile(away!, LAN, { alternateHttpBaseUrls: [TUNNEL] });
    expect(back?.lastGoodHttpBaseUrl).toBe(LAN);
  });

  it("writes nothing when nothing changed, never lists the paired host, drops a gone tunnel", () => {
    const settled = profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: LAN });
    expect(learnedBearerProfile(settled, LAN, { alternateHttpBaseUrls: [TUNNEL] })).toBeNull();
    expect(learnedBearerProfile(settled, LAN, { alternateHttpBaseUrls: [LAN, TUNNEL] })).toBeNull();
    const gone = learnedBearerProfile(settled, LAN, {});
    expect(gone?.alternateHttpBaseUrls).toBeUndefined();
    expect(gone?.lastGoodHttpBaseUrl).toBe(LAN);
  });
});
