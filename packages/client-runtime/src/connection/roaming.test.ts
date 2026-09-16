import { EnvironmentId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { BearerConnectionProfile } from "./catalog.ts";
import { ConnectionBlockedError, ConnectionTransientError } from "./model.ts";
import {
  bearerHostOrder,
  isPublicHost,
  learnedBearerProfile,
  normalizedAlternates,
  roamsPast,
} from "./roaming.ts";

const LAN = "http://192.168.100.61:3773/";
const TUNNEL = "https://code.infinitus.run/";

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
  it("dials the tunnel before the LAN address, whichever worked last or was paired", () => {
    expect(bearerHostOrder(profile())).toEqual([LAN]);
    expect(bearerHostOrder(profile({ alternateHttpBaseUrls: [TUNNEL] }))).toEqual([TUNNEL, LAN]);
    expect(
      bearerHostOrder(profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: LAN })),
    ).toEqual([TUNNEL, LAN]);
    expect(bearerHostOrder(profile({ httpBaseUrl: TUNNEL, alternateHttpBaseUrls: [LAN] }))).toEqual(
      [TUNNEL, LAN],
    );
  });

  it("orders each class by the host that worked last, then the paired one, once each", () => {
    const other = "https://other.example.test/";
    expect(
      bearerHostOrder(
        profile({ alternateHttpBaseUrls: [TUNNEL, other], lastGoodHttpBaseUrl: other }),
      ),
    ).toEqual([other, TUNNEL, LAN]);
    expect(
      bearerHostOrder(profile({ alternateHttpBaseUrls: [TUNNEL, LAN], lastGoodHttpBaseUrl: LAN })),
    ).toEqual([TUNNEL, LAN]);
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
    ).toEqual(["https://new.example.test", LAN]);
  });
});

describe("isPublicHost", () => {
  it("is an https hostname, never an address of one network", () => {
    expect(isPublicHost(TUNNEL)).toBe(true);
    expect(isPublicHost("https://abc-def.trycloudflare.com/")).toBe(true);
    expect(isPublicHost(LAN)).toBe(false);
    expect(isPublicHost("http://100.69.163.65:3773/")).toBe(false);
    expect(isPublicHost("https://10.0.0.2/")).toBe(false);
    expect(isPublicHost("http://mac.local:3773/")).toBe(false);
    expect(isPublicHost("http://localhost:3773/")).toBe(false);
    expect(isPublicHost("https://[::1]:3773/")).toBe(false);
    expect(isPublicHost("http://code.infinitus.run/")).toBe(false);
    expect(isPublicHost("not a url")).toBe(false);
  });
});

describe("normalizedAlternates", () => {
  it("shapes the server's hosts like a paired one, so a pairing over the tunnel has no alternate", () => {
    expect(normalizedAlternates(["https://code.infinitus.run"], LAN)).toEqual([TUNNEL]);
    expect(normalizedAlternates(["https://code.infinitus.run"], TUNNEL)).toEqual([]);
    expect(
      normalizedAlternates(["https://code.infinitus.run/", "https://code.infinitus.run"], LAN),
    ).toEqual([TUNNEL]);
    expect(normalizedAlternates(["not a url", "wss://code.infinitus.run"], LAN)).toEqual([TUNNEL]);
    expect(normalizedAlternates(undefined, LAN)).toEqual([]);
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
    const learned = learnedBearerProfile(paired, LAN, {
      alternateHttpBaseUrls: ["https://code.infinitus.run"],
    });
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

  it("keeps a named tunnel through a connect that names none, and takes the one named now", () => {
    const settled = profile({ alternateHttpBaseUrls: [TUNNEL], lastGoodHttpBaseUrl: LAN });
    expect(learnedBearerProfile(settled, LAN, {})).toBeNull();
    expect(learnedBearerProfile(settled, LAN, { alternateHttpBaseUrls: [] })).toBeNull();
    const moved = learnedBearerProfile(settled, LAN, {
      alternateHttpBaseUrls: ["https://other.example.test"],
    });
    expect(moved?.alternateHttpBaseUrls).toEqual(["https://other.example.test/"]);
    expect(bearerHostOrder(moved!)).toEqual(["https://other.example.test/", LAN]);
  });

  it("drops a quick tunnel the server no longer names", () => {
    const quick = "https://abc-def.trycloudflare.com/";
    const settled = profile({ alternateHttpBaseUrls: [quick, TUNNEL], lastGoodHttpBaseUrl: LAN });
    const gone = learnedBearerProfile(settled, LAN, {});
    expect(gone?.alternateHttpBaseUrls).toEqual([TUNNEL]);
    expect(
      learnedBearerProfile(profile({ alternateHttpBaseUrls: [quick] }), LAN, {})
        ?.alternateHttpBaseUrls,
    ).toBeUndefined();
  });
});
