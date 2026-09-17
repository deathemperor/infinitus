import type { InfinitusManifestCommand } from "@infinitus/contracts/infinitus";
import { describe, expect, it } from "vite-plus/test";

import {
  crashDetail,
  crashesInput,
  crashesSupported,
  crashSummary,
  crashTranscriptInput,
  parseCrashes,
} from "./crashes.logic";

const command = (
  name: string,
  options: ReadonlyArray<string> = [],
): InfinitusManifestCommand => ({
  name,
  args: [],
  options,
  effect: "read",
  summary: "",
  replyShape: "",
});

const report = {
  id: "crash-1",
  platform: "mac",
  device: "HyperNovae",
  appVersion: "0.5.0-alpha.13",
  osVersion: "macOS 26.7",
  at: "2026-09-15T12:04:00.000Z",
  kind: "crash",
  reason: "EXC_BAD_ACCESS SIGSEGV",
  frames: ["Infinitus +0x1234 main"],
};

describe("crashesSupported", () => {
  it("takes a build whose crashes verb answers --id", () => {
    expect(crashesSupported([command("crashes", ["--id <id>"]), command("status")])).toBe(true);
  });

  it("refuses a build whose crashes verb predates --id, and one without the verb", () => {
    expect(crashesSupported([command("crashes")])).toBe(false);
    expect(crashesSupported([command("status")])).toBe(false);
  });
});

describe("parseCrashes", () => {
  it("reads the list, and the transcript a --id read adds", () => {
    expect(parseCrashes({ crashes: [report] })).toEqual([report]);
    const one = parseCrashes({ crashes: [{ ...report, transcript: "reason: …" }] });
    expect(one?.[0]?.transcript).toBe("reason: …");
  });

  it("answers null for a reply of another shape", () => {
    expect(parseCrashes({ crashes: [{ id: "crash-1" }] })).toBeNull();
    expect(parseCrashes({ reports: [] })).toBeNull();
    expect(parseCrashes(null)).toBeNull();
  });
});

describe("crashesInput", () => {
  it("asks for every report, and for one by id", () => {
    expect(crashesInput()).toEqual({ command: "crashes", args: [], options: {} });
    expect(crashTranscriptInput("crash-1")).toEqual({
      command: "crashes",
      args: [],
      options: { id: "crash-1" },
    });
  });
});

describe("crash lines", () => {
  it("summarises a report the way the Mac did", () => {
    expect(crashSummary(report)).toBe("HyperNovae · crash · EXC_BAD_ACCESS SIGSEGV");
    expect(crashDetail(report, "en-US")).toContain("app 0.5.0-alpha.13 · macOS 26.7");
    expect(crashDetail(report, "en-US")).toContain("Sep 15, 2026");
  });

  it("shows a timestamp it cannot parse verbatim rather than Invalid Date", () => {
    expect(crashDetail({ ...report, at: "whenever" }, "en-US")).toContain("whenever");
  });
});
