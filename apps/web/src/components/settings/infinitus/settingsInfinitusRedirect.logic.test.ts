import { describe, expect, it } from "vite-plus/test";

import { redirectedInfinitusSettingsPath } from "./settingsInfinitusRedirect.logic";

describe("redirectedInfinitusSettingsPath", () => {
  it("sends the old group root to the Menu bar page", () => {
    expect(redirectedInfinitusSettingsPath(undefined)).toBe("/settings/menu-bar");
    expect(redirectedInfinitusSettingsPath("")).toBe("/settings/menu-bar");
    expect(redirectedInfinitusSettingsPath("/")).toBe("/settings/menu-bar");
  });

  it("maps every old page, the renamed Priority slug and the nested Activity", () => {
    expect(redirectedInfinitusSettingsPath("engines/")).toBe("/settings/engines");
    expect(redirectedInfinitusSettingsPath("sessions")).toBe("/settings/priority");
    expect(redirectedInfinitusSettingsPath("engines/activity")).toBe("/settings/engines/activity");
  });

  it("sends an unknown page to the Menu bar page rather than nowhere", () => {
    expect(redirectedInfinitusSettingsPath("profiles")).toBe("/settings/menu-bar");
  });
});
