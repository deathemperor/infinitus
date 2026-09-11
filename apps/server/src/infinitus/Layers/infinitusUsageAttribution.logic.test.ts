import { describe, expect, it } from "vite-plus/test";

import {
  accountAtFactory,
  describeAccount,
  readSwitches,
} from "./infinitusUsageAttribution.logic.ts";

const reply = {
  switches: [
    {
      ts: "2026-08-01T10:00:00Z",
      to: { slot: 1, email: "one@example.invalid" },
      trigger: "manual",
    },
    {
      ts: "2026-08-02T10:00:00Z",
      from: { slot: 1, email: "one@example.invalid" },
      to: { slot: 2, email: "two@example.invalid" },
      trigger: "failover",
    },
    { ts: "not a date", to: { slot: 3, email: "bad@example.invalid" }, trigger: "manual" },
    { ts: "2026-08-03T10:00:00Z", to: { slot: 4 }, trigger: "manual" },
    "garbage",
  ],
};

describe("readSwitches", () => {
  it("keeps the rows with an instant and a destination email, in time order", () => {
    expect(readSwitches(reply)).toEqual([
      { atMs: Date.parse("2026-08-01T10:00:00Z"), email: "one@example.invalid" },
      { atMs: Date.parse("2026-08-02T10:00:00Z"), email: "two@example.invalid" },
    ]);
  });

  it("reads nothing from a reply that is not a switch list", () => {
    expect(readSwitches(null)).toEqual([]);
    expect(readSwitches({ switches: "no" })).toEqual([]);
  });

  it("sorts an out-of-order log", () => {
    const rows = readSwitches({
      switches: [
        { ts: "2026-08-02T10:00:00Z", to: { email: "b@example.invalid" } },
        { ts: "2026-08-01T10:00:00Z", to: { email: "a@example.invalid" } },
      ],
    });
    expect(rows.map((row) => row.email)).toEqual(["a@example.invalid", "b@example.invalid"]);
  });
});

describe("accountAtFactory", () => {
  const accountAt = accountAtFactory(readSwitches(reply));

  it("names the account of the latest switch at or before the instant", () => {
    expect(accountAt(Date.parse("2026-08-01T12:00:00Z"))).toBe("one@example.invalid");
    expect(accountAt(Date.parse("2026-08-09T00:00:00Z"))).toBe("two@example.invalid");
  });

  it("knows nothing before the first logged switch", () => {
    expect(accountAt(Date.parse("2026-08-01T09:59:59.999Z"))).toBeNull();
  });

  it("refuses the switch's own second, on either side of the instant", () => {
    expect(accountAt(Date.parse("2026-08-02T10:00:00.000Z"))).toBeNull();
    expect(accountAt(Date.parse("2026-08-02T10:00:00.999Z"))).toBeNull();
    expect(accountAt(Date.parse("2026-08-02T10:00:01.000Z"))).toBe("two@example.invalid");
    expect(accountAt(Date.parse("2026-08-02T09:59:59.999Z"))).toBe("one@example.invalid");
  });

  it("answers null for every instant when the log is empty", () => {
    expect(accountAtFactory([])(Date.parse("2026-08-02T10:00:00Z"))).toBeNull();
  });
});

describe("describeAccount", () => {
  const accounts = [
    { number: 1, email: "one@example.invalid", alias: "work" },
    { number: 2, email: "two@example.invalid" },
  ];

  it("uses the alias, else the email, and the current slot", () => {
    expect(describeAccount(accounts, "one@example.invalid")).toEqual({ label: "work", number: 1 });
    expect(describeAccount(accounts, "two@example.invalid")).toEqual({
      label: "two@example.invalid",
      number: 2,
    });
  });

  it("labels an account that left the fleet by its email, without a number", () => {
    expect(describeAccount(accounts, "gone@example.invalid")).toEqual({
      label: "gone@example.invalid",
    });
  });
});
