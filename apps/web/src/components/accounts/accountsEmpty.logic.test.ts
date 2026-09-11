import { describe, expect, it } from "vite-plus/test";

import type { EngineStatusRow } from "../settings/infinitus/panel.logic";
import {
  accountsEmptyMessage,
  accountsEmptyReason,
  accountsEmptyShowsSetupGuide,
} from "./accountsEmpty.logic";

const engine = (over: Partial<EngineStatusRow>): EngineStatusRow => ({
  key: "swapd",
  label: "swapd",
  enabled: true,
  registered: true,
  keyState: "none",
  ...over,
});

describe("accountsEmptyReason", () => {
  it("reads an app that reports no engine as nothing installed", () => {
    expect(accountsEmptyReason([])).toBe("no-engines");
  });

  it("reads a known but unregistered engine as nothing installed yet", () => {
    expect(accountsEmptyReason([engine({ registered: false })])).toBe("none-registered");
  });

  it("reads a registered engine that is off as a switch to flip", () => {
    expect(accountsEmptyReason([engine({ enabled: false })])).toBe("all-disabled");
  });

  it("reads a running engine with no fleet as a missing account", () => {
    expect(accountsEmptyReason([engine({})])).toBe("no-accounts");
  });

  it("ignores an unregistered engine when another one runs", () => {
    expect(accountsEmptyReason([engine({}), engine({ key: "9router", registered: false })])).toBe(
      "no-accounts",
    );
  });
});

describe("accountsEmptyShowsSetupGuide", () => {
  it("offers the install guide only where there is nothing to turn on", () => {
    expect(accountsEmptyShowsSetupGuide("no-engines")).toBe(true);
    expect(accountsEmptyShowsSetupGuide("none-registered")).toBe(true);
    expect(accountsEmptyShowsSetupGuide("all-disabled")).toBe(false);
    expect(accountsEmptyShowsSetupGuide("no-accounts")).toBe(false);
  });
});

describe("accountsEmptyMessage", () => {
  it("names the next step for every reason", () => {
    expect(accountsEmptyMessage("all-disabled")).toContain("Settings › Infinitus › Engines");
    expect(accountsEmptyMessage("no-accounts")).toContain("register");
  });
});
