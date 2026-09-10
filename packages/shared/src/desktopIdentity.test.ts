import { describe, expect, it } from "vite-plus/test";

import {
  adoptsLegacyDesktopUserDataDir,
  DESKTOP_DEV_URL_SCHEME,
  DESKTOP_DEV_USER_DATA_DIR_NAME,
  DESKTOP_URL_SCHEME,
  DESKTOP_USER_DATA_DIR_NAME,
} from "./desktopIdentity.ts";

describe("the fork's desktop identity", () => {
  it("never reuses the installed T3 Code's URL scheme", () => {
    expect(DESKTOP_URL_SCHEME).toBe("infinitus");
    expect(DESKTOP_DEV_URL_SCHEME).toBe("infinitus-dev");
  });

  it("never reuses the installed T3 Code's userData directory", () => {
    expect(DESKTOP_USER_DATA_DIR_NAME).toBe("infinitus-desktop");
    expect(DESKTOP_DEV_USER_DATA_DIR_NAME).toBe("infinitus-desktop-dev");
  });

  it("never shares the native Infinitus app's Application Support directory (case-insensitive APFS)", () => {
    for (const name of [DESKTOP_USER_DATA_DIR_NAME, DESKTOP_DEV_USER_DATA_DIR_NAME]) {
      expect(name.toLowerCase()).not.toBe("infinitus");
    }
  });

  it("adopts no legacy userData directory, least of all the installed app's", () => {
    expect(adoptsLegacyDesktopUserDataDir("T3 Code (Alpha)")).toBe(false);
    expect(adoptsLegacyDesktopUserDataDir("T3 Code (Dev)")).toBe(false);
    expect(adoptsLegacyDesktopUserDataDir("t3code")).toBe(false);
  });
});
