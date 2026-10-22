import { DEFAULT_UNIFIED_SETTINGS } from "@infinitus/contracts";
import * as Duration from "effect/Duration";
import { describe, expect, it } from "vite-plus/test";
import {
  backgroundActivitySharedPolicySettings,
  getChangedBrowserSettingLabels,
  hasChangedBackgroundActivitySettings,
<<<<<<< HEAD
  isProjectGroupingEnabled,
  projectGroupingModeFromToggle,
  resolveBackgroundActivityProfileOption,
  resolveDesktopUpdateTrackRow,
=======
>>>>>>> upstream-sync-43879d970-upstream-renamed
} from "./SettingsPanels.logic";

describe("background activity settings restore", () => {
  it("detects legacy interval values even when the structured setting is at its default", () => {
    expect(
      hasChangedBackgroundActivitySettings({
        backgroundActivity: DEFAULT_UNIFIED_SETTINGS.backgroundActivity,
        backgroundActivityProfile: DEFAULT_UNIFIED_SETTINGS.backgroundActivityProfile,
        automaticGitFetchInterval: Duration.seconds(45),
        providerHealthRefreshInterval: DEFAULT_UNIFIED_SETTINGS.providerHealthRefreshInterval,
      }),
    ).toBe(true);
    expect(
      hasChangedBackgroundActivitySettings({
        backgroundActivity: DEFAULT_UNIFIED_SETTINGS.backgroundActivity,
        backgroundActivityProfile: DEFAULT_UNIFIED_SETTINGS.backgroundActivityProfile,
        automaticGitFetchInterval: DEFAULT_UNIFIED_SETTINGS.automaticGitFetchInterval,
        providerHealthRefreshInterval: Duration.minutes(7),
      }),
    ).toBe(true);
    expect(hasChangedBackgroundActivitySettings(DEFAULT_UNIFIED_SETTINGS)).toBe(false);
  });

  it("preserves advanced overrides when the shared policy changes", () => {
    const automaticGitFetchInterval = Duration.seconds(42);
    expect(
      backgroundActivitySharedPolicySettings(
        {
          ...DEFAULT_UNIFIED_SETTINGS,
          backgroundActivity: {
            schemaVersion: 1,
            profile: "custom",
            baseProfile: "balanced",
            overrides: {
              automaticGitFetchInterval,
              pauseWhenOnBattery: true,
            },
          },
        },
        "performance",
      ),
    ).toEqual({
      schemaVersion: 1,
      profile: "custom",
      baseProfile: "performance",
      overrides: {
        automaticGitFetchInterval,
        pauseWhenOnBattery: true,
      },
    });
  });

  it("materializes legacy advanced overrides before changing the shared policy", () => {
    const automaticGitFetchInterval = Duration.seconds(42);
    expect(
      backgroundActivitySharedPolicySettings(
        {
          ...DEFAULT_UNIFIED_SETTINGS,
          automaticGitFetchInterval,
        },
        "battery-saver",
      ),
    ).toEqual({
      schemaVersion: 1,
      profile: "custom",
      baseProfile: "battery-saver",
      overrides: {
        automaticGitFetchInterval,
      },
    });
  });
});

describe("getChangedBrowserSettingLabels", () => {
  it("counts a retained custom search URL so restore clears it", () => {
    expect(
      getChangedBrowserSettingLabels({
        ...DEFAULT_UNIFIED_SETTINGS,
        browserCustomSearchUrl: "https://search.example/?q=%s",
      }),
    ).toEqual(["Search engine"]);
  });
});

describe("resolveDesktopUpdateTrackRow", () => {
  it("offers an Infinitus build its Release and Nightly tracks, and never upstream's (#1042)", () => {
    const row = resolveDesktopUpdateTrackRow("infinitus");

    expect(row.label).toBe("Release");
    expect(row.switchable).toBe(true);
    expect(row.options.map((option) => option.value)).toEqual(["infinitus", "infinitus-nightly"]);
    expect(resolveDesktopUpdateTrackRow("infinitus-nightly")).toMatchObject({
      label: "Nightly",
      switchable: true,
      options: row.options,
    });
  });

  it("offers no switch before the desktop bridge reports a track", () => {
    const row = resolveDesktopUpdateTrackRow(null);

    expect(row.switchable).toBe(false);
    expect(row.label).not.toBe("Stable");
  });

  it("keeps upstream's two switchable tracks", () => {
    expect(resolveDesktopUpdateTrackRow("latest")).toMatchObject({
      label: "Stable",
      switchable: true,
    });
    expect(resolveDesktopUpdateTrackRow("nightly")).toMatchObject({
      label: "Nightly",
      switchable: true,
    });
    expect(resolveDesktopUpdateTrackRow("latest").options.map((option) => option.value)).toEqual([
      "latest",
      "nightly",
    ]);
  });
});
