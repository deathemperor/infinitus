import { describe, expect, it } from "vite-plus/test";

import {
  parsePolicy,
  policyFleets,
  policyReadInput,
  policyRows,
  policySetInput,
  policySupported,
  policyUnsetInput,
  policyWireValue,
} from "./policy.logic";

const command = (name: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
});

const SETTINGS = [
  { key: "claude.enabled", value: true, isSet: false, default: true, help: "Auto-switching on/off" },
  { key: "claude.threshold", value: 99.9, isSet: true, default: 90, help: "Switch when…" },
  { key: "claude.strategy", value: "consume-first", isSet: true, default: "best", help: "How…" },
  { key: "claude.model", value: ["Fable", "Opus"], isSet: true, default: [], help: "Also…" },
  { key: "claude.newKnob", value: "x", isSet: false, default: "x", help: "A knob this build never saw" },
];

describe("policySupported", () => {
  it("needs the read verb and both write verbs", () => {
    const all = [command("policy"), command("policy-set"), command("policy-unset")];
    expect(policySupported(all)).toBe(true);
    expect(policySupported(all.filter((c) => c.name !== "policy-unset"))).toBe(false);
    expect(policySupported([])).toBe(false);
  });
});

describe("policyFleets", () => {
  it("keeps the fleets whose engine has the settings capability, whatever its name", () => {
    const fleet = (key: string, capabilities: string[]) => ({
      key,
      engineID: key.split("/")[0]!,
      provider: "claude",
      capabilities,
      accounts: [],
    });
    const fleets = [
      fleet("swapd/claude", ["switch", "settings"]),
      fleet("cliproxy/claude", ["switch"]),
      fleet("other/claude", ["settings"]),
    ];
    expect(policyFleets(fleets).map((f) => f.key)).toEqual(["swapd/claude", "other/claude"]);
  });
});

describe("policy inputs", () => {
  it("name the fleet, the bare key and the value as the verbs take them", () => {
    expect(policyReadInput("swapd/claude")).toEqual({
      command: "policy",
      args: ["swapd/claude"],
      options: {},
    });
    expect(policySetInput("swapd/claude", "strategy", "best")).toEqual({
      command: "policy-set",
      args: ["swapd/claude", "strategy", "best"],
      options: {},
    });
    expect(policyUnsetInput("swapd/claude", "model")).toEqual({
      command: "policy-unset",
      args: ["swapd/claude", "model"],
      options: {},
    });
  });
});

describe("parsePolicy", () => {
  it("reads the engine's settings whole and refuses another shape", () => {
    const parsed = parsePolicy({ fleet: "swapd/claude", settings: SETTINGS });
    expect(parsed?.settings.map((s) => s.key)).toEqual(SETTINGS.map((s) => s.key));
    expect(parsePolicy({ fleet: "swapd/claude" })).toBeNull();
    expect(parsePolicy({ fleet: "swapd/claude", settings: [{ key: "k" }] })).toBeNull();
  });
});

describe("policyRows", () => {
  const rows = policyRows(SETTINGS);
  const row = (key: string) => rows.find((r) => r.key === key)!;

  it("strips the provider prefix and keeps the engine's order and help", () => {
    expect(rows.map((r) => r.key)).toEqual(["enabled", "threshold", "strategy", "model", "newKnob"]);
    expect(row("threshold").help).toBe("Switch when…");
  });

  it("picks the control from the value's type, and a select for the strategy", () => {
    expect(row("enabled").control).toEqual({ kind: "switch" });
    expect(row("enabled").on).toBe(true);
    expect(row("threshold").control).toEqual({ kind: "number" });
    expect(row("strategy").control).toEqual({
      kind: "select",
      choices: ["best", "consume-first", "next-available"],
    });
    expect(row("model").control).toEqual({ kind: "text" });
  });

  it("shows a list joined with a comma and space, and the default the same way", () => {
    expect(row("model").value).toBe("Fable, Opus");
    expect(row("model").defaultText).toBe("");
    expect(row("threshold").value).toBe("99.9");
    expect(row("threshold").defaultText).toBe("90");
    expect(row("enabled").defaultText).toBe("on");
  });

  it("names a knob it knows in plain words and an unknown one by its key", () => {
    expect(row("strategy").label).toBe("Strategy");
    expect(row("newKnob").label).toBe("newKnob");
    expect(row("newKnob").control).toEqual({ kind: "text" });
    expect(row("newKnob").isSet).toBe(false);
  });
});

describe("policyWireValue", () => {
  const rows = policyRows(SETTINGS);
  const row = (key: string) => rows.find((r) => r.key === key)!;

  it("sends a list comma-joined without the field's spaces, and a number as typed", () => {
    expect(policyWireValue(row("model"), " Fable , Opus, ")).toBe("Fable,Opus");
    expect(policyWireValue(row("model"), "")).toBe("");
    expect(policyWireValue(row("threshold"), " 95 ")).toBe("95");
    expect(policyWireValue(row("strategy"), "best")).toBe("best");
  });
});
