import { describe, expect, it } from "vite-plus/test";
import { type DesktopUpdateState, EnvironmentId } from "@infinitus/contracts";

import {
  canCheckForUpdate,
  countRunningLocalTurns,
  getDesktopUpdateArmedDialog,
  getDesktopUpdateArmedTooltip,
  getDesktopUpdateButtonTooltip,
  getDesktopUpdateReleaseHistoryUrl,
  getDesktopUpdateReleaseUrl,
  getDesktopUpdateRunningTurnsDialog,
  resolveDesktopUpdateButtonAction,
  resolveInstallWhenIdleStep,
} from "./desktopUpdate.logic";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

const baseState: DesktopUpdateState = {
  enabled: true,
  status: "idle",
  channel: "latest",
  currentVersion: "1.0.0",
  hostArch: "x64",
  appArch: "x64",
  runningUnderArm64Translation: false,
  availableVersion: null,
  downloadedVersion: null,
  releaseNotes: [],
  omittedReleaseCount: 0,
  downloadPercent: null,
  checkedAt: null,
  message: null,
  errorContext: null,
  canRetry: false,
};

describe("desktop update button state", () => {
  it("keeps retry action available after a download error", () => {
    const state: DesktopUpdateState = {
      ...baseState,
      status: "error",
      availableVersion: "1.1.0",
      message: "network timeout",
      errorContext: "download",
      canRetry: true,
    };
    expect(resolveDesktopUpdateButtonAction(state)).toBe("download");
    expect(getDesktopUpdateButtonTooltip(state)).toContain("Click to retry");
  });

  it("prefers a newly available release over a stale downloaded version", () => {
    const state: DesktopUpdateState = {
      ...baseState,
      status: "available",
      availableVersion: "1.2.0",
      downloadedVersion: "1.1.0",
    };
    expect(resolveDesktopUpdateButtonAction(state)).toBe("download");
  });

  it("hides the install action while checking for a newer release", () => {
    const state: DesktopUpdateState = {
      ...baseState,
      status: "checking",
      availableVersion: "1.1.0",
      downloadedVersion: "1.1.0",
      downloadPercent: 100,
    };
    expect(resolveDesktopUpdateButtonAction(state)).toBe("none");
  });
});

describe("desktop update UI helpers", () => {
  it.each(["owner/repo/extra", "owner#notes/repo", "owner/repo?tab=notes"])(
    "falls back to upstream for an invalid configured repository: %s",
    (repository) => {
      expect(getDesktopUpdateReleaseHistoryUrl(repository)).toBe(
        "https://github.com/pingdotgg/t3code/releases",
      );
      expect(getDesktopUpdateReleaseUrl("1.2.3", repository)).toBe(
        "https://github.com/pingdotgg/t3code/releases/tag/v1.2.3",
      );
    },
  );
});

describe("canCheckForUpdate", () => {
  it("returns true once an update has been downloaded so newer releases can be found", () => {
    expect(
      canCheckForUpdate({
        ...baseState,
        status: "downloaded",
        availableVersion: "1.1.0",
        downloadedVersion: "1.1.0",
      }),
    ).toBe(true);
  });
});

describe("running local turns before a desktop install (#829)", () => {
  const local = EnvironmentId.make("env-local");
  const remote = EnvironmentId.make("env-remote");
  const shells = [
    { environmentId: local, source: { activityRunStatus: "running" as const } },
    { environmentId: local, source: { activityRunStatus: "waiting" as const } },
    { environmentId: local, source: { activityRunStatus: null } },
    { environmentId: local, source: {} },
    { environmentId: remote, source: { activityRunStatus: "preparing" as const } },
  ];

  it("counts live runs on local backends only, a waiting run included", () => {
    expect(countRunningLocalTurns(shells, (id) => id === local)).toBe(2);
    expect(countRunningLocalTurns(shells, () => true)).toBe(3);
    expect(countRunningLocalTurns([], () => true)).toBe(0);
  });

  it("words the dialog by count and offers only an immediate install for an unknown count", () => {
    const state = { availableVersion: "0.5.0-alpha.4", downloadedVersion: "0.5.0-alpha.4" };
    expect(getDesktopUpdateRunningTurnsDialog(1, state)).toEqual({
      title: `Install update 0.5.0-alpha.4 and restart ${PRODUCT_NAME}?`,
      description:
        "1 running thread would be interrupted. Install when it finishes, or install now and cut it off.",
    });
    expect(getDesktopUpdateRunningTurnsDialog(3, state).description).toBe(
      "3 running threads would be interrupted. Install when they finish, or install now and cut them off.",
    );
    expect(getDesktopUpdateRunningTurnsDialog(null, state).title).toBe(
      "Could not confirm no threads are running",
    );
    expect(getDesktopUpdateArmedDialog(1).title).toBe("Installing when 1 running thread finishes");
    expect(getDesktopUpdateArmedDialog(2).title).toBe("Installing when 2 running threads finish");
    expect(getDesktopUpdateArmedTooltip(1)).toBe(
      "Installs when 1 running thread finishes. Click to cancel.",
    );
    expect(getDesktopUpdateArmedTooltip(2)).toBe(
      "Installs when 2 running threads finish. Click to cancel.",
    );
  });

  it("keeps the armed wait through a newer release and fires once it is downloaded", () => {
    // #1037: the wait was armed on 1.2.4 with a thread running; 1.2.5 arrives.
    const downloaded = {
      ...baseState,
      status: "downloaded" as const,
      availableVersion: "1.2.4",
      downloadedVersion: "1.2.4",
    };
    expect(resolveInstallWhenIdleStep(downloaded, "install", 1)).toBe("wait");
    const superseded = {
      ...downloaded,
      status: "available" as const,
      availableVersion: "1.2.5",
      downloadedVersion: null,
    };
    expect(resolveInstallWhenIdleStep(superseded, "download", 1)).toBe("wait");
    const downloading = { ...superseded, status: "downloading" as const };
    expect(resolveInstallWhenIdleStep(downloading, "none", 0)).toBe("wait");
    const newer = { ...superseded, status: "downloaded" as const, downloadedVersion: "1.2.5" };
    expect(resolveInstallWhenIdleStep(newer, "install", 1)).toBe("wait");
    expect(resolveInstallWhenIdleStep(newer, "install", 0)).toBe("install");
  });

  it("drops the armed wait only when nothing is left to install", () => {
    const upToDate = {
      ...baseState,
      status: "up-to-date" as const,
      availableVersion: null,
      downloadedVersion: null,
    };
    expect(resolveInstallWhenIdleStep(upToDate, "none", 0)).toBe("disarm");
    expect(resolveInstallWhenIdleStep(null, "none", 0)).toBe("disarm");
    const checking = {
      ...baseState,
      status: "checking" as const,
      availableVersion: "1.2.4",
      downloadedVersion: "1.2.4",
    };
    expect(resolveInstallWhenIdleStep(checking, "none", 0)).toBe("wait");
  });
});
