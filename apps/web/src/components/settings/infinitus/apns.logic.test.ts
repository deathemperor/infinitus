import { describe, expect, it } from "vite-plus/test";

import {
  apnsKeyIdFromPrefs,
  apnsSupported,
  isPemPrivateKey,
  parseApnsStatus,
  registrationLine,
} from "./apns.logic";

const command = (name: string, stdin?: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});

describe("apnsSupported", () => {
  it("needs the read verb and the key verb marked stdin secret", () => {
    expect(apnsSupported([command("apns"), command("apns-key", "secret")])).toBe(true);
    expect(apnsSupported([command("apns"), command("apns-key")])).toBe(false);
    expect(apnsSupported([command("apns-key", "secret")])).toBe(false);
  });
});

describe("parseApnsStatus", () => {
  it("reads the setup and every registration", () => {
    expect(
      parseApnsStatus({
        keyPresent: true,
        teamId: "TEAM123456",
        keyId: "KEY1234567",
        registrations: [
          {
            deviceId: "d1",
            deviceName: "Ada's iPhone",
            kind: "alert",
            environment: "production",
            registeredAt: "2026-09-14T09:00:00Z",
          },
        ],
      }),
    ).toEqual({
      keyPresent: true,
      teamId: "TEAM123456",
      keyId: "KEY1234567",
      registrations: [
        {
          deviceId: "d1",
          deviceName: "Ada's iPhone",
          kind: "alert",
          environment: "production",
          registeredAt: "2026-09-14T09:00:00Z",
        },
      ],
    });
  });

  it("drops a registration it cannot read and keeps the rest", () => {
    const parsed = parseApnsStatus({
      keyPresent: false,
      teamId: "",
      keyId: "",
      registrations: [
        { deviceId: "d1" },
        {
          deviceId: "d2",
          deviceName: "Phone",
          kind: "alert",
          environment: "sandbox",
          registeredAt: "2026-09-14T09:00:00Z",
        },
      ],
    });
    expect(parsed?.registrations.map((row) => row.deviceId)).toEqual(["d2"]);
  });

  it("is null for a shape it cannot read", () => {
    expect(parseApnsStatus({ registrations: [] })).toBeNull();
    expect(parseApnsStatus(null)).toBeNull();
  });
});

describe("isPemPrivateKey", () => {
  it("accepts a .p8's PEM header and refuses anything else", () => {
    expect(
      isPemPrivateKey("-----BEGIN PRIVATE KEY-----\nMIGT...\n-----END PRIVATE KEY-----\n"),
    ).toBe(true);
    expect(isPemPrivateKey("  \n-----BEGIN PRIVATE KEY-----\nx")).toBe(true);
    expect(isPemPrivateKey("-----BEGIN CERTIFICATE-----\nx")).toBe(false);
    expect(isPemPrivateKey("")).toBe(false);
  });
});

describe("apnsKeyIdFromPrefs", () => {
  it("reads the apns_key_id pref's value, blank when unset or absent", () => {
    const pref = (value: unknown) => ({
      key: "apns_key_id",
      type: "string" as const,
      default: "",
      value,
      section: "devices",
      effect: "live" as const,
    });
    expect(apnsKeyIdFromPrefs({ sections: [], prefs: [pref("KEY1234567")] })).toBe("KEY1234567");
    expect(apnsKeyIdFromPrefs({ sections: [], prefs: [pref("")] })).toBe("");
    expect(apnsKeyIdFromPrefs({ sections: [], prefs: [pref(3)] })).toBe("");
    expect(apnsKeyIdFromPrefs(undefined)).toBe("");
  });
});

describe("registrationLine", () => {
  it("names the phone, the kind and the environment", () => {
    expect(
      registrationLine({
        deviceId: "d1",
        deviceName: "Ada's iPhone",
        kind: "alert",
        environment: "production",
        registeredAt: "2026-09-14T09:00:00Z",
      }),
    ).toBe("Ada's iPhone · alert · production");
  });
});
