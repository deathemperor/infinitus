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

  it("never tries a last-good host the server no longer names", () => {
    expect(bearerHostOrder(profile({ lastGoodHttpBaseUrl: TUNNEL }))).toEqual([LAN]);
    expect(
      bearerHostOrder(
        profile({
          alternateHttpBaseUrls: ["https://new.example.test"],
          lastGoodHttpBaseUrl: TUNNEL,
        }),
      ),
    ).toEqual([LAN, "https://new.example.test"]);
  });
});

describe("roamsPast", () => {
  it("walks past a host where the Mac is not, never one that refused the credential", () => {
    const transient = (reason: ConnectionTransientError["reason"]) =>
      roamsPast(new ConnectionTransientError({ reason, detail: "x" }));
    const blocked = (reason: ConnectionBlockedError["reason"]) =>
      roamsPast(new ConnectionBlockedError({ reason, detail: "x" }));
    expect(transient("network")).toBe(true);
    expect(transient("timeout")).toBe(true);
    expect(transient("remote-unavailable")).toBe(true);
    expect(blocked("configuration")).toBe(true);
    expect(transient("transport")).toBe(false);
    expect(blocked("authentication")).toBe(false);
    expect(blocked("permission")).toBe(false);
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

  it("writes nothing when nothing changed and never lists the paired host", () => {
    const settled = profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: LAN });
    expect(learnedBearerProfile(settled, LAN, { alternateHttpBaseUrls: [TUNNEL] })).toBeNull();
    expect(learnedBearerProfile(settled, LAN, { alternateHttpBaseUrls: [LAN, TUNNEL] })).toBeNull();
  });

  it("drops a tunnel the server no longer names and takes the one it names now", () => {
    const settled = profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: LAN });
    const gone = learnedBearerProfile(settled, LAN, {});
    expect(gone?.alternateHttpBaseUrls).toBeUndefined();
    expect(gone?.lastGoodHttpBaseUrl).toBe(LAN);
    expect(
      learnedBearerProfile(settled, LAN, { alternateHttpBaseUrls: [] })?.alternateHttpBaseUrls,
    ).toBeUndefined();
    const moved = learnedBearerProfile(settled, LAN, {
      alternateHttpBaseUrls: ["https://other.example.test"],
    });
    expect(moved?.alternateHttpBaseUrls).toEqual(["https://other.example.test"]);
    expect(bearerHostOrder(moved!)).toEqual([LAN, "https://other.example.test"]);
  });
});
