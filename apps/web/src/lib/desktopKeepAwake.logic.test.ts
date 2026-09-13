import type { EnvironmentId, OrchestrationSessionStatus } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { keepAwakeWanted } from "./desktopKeepAwake.logic";

const local = "env-local" as EnvironmentId;
const remote = "env-remote" as EnvironmentId;
const shell = (environmentId: EnvironmentId, status: OrchestrationSessionStatus | null) => ({
  environmentId,
  session: status === null ? null : { status },
});

describe("keepAwakeWanted", () => {
  it("holds while a thread on the primary environment has a turn starting or running", () => {
    expect(
      keepAwakeWanted({
        enabled: true,
        primaryEnvironmentId: local,
        shells: [shell(local, "ready"), shell(local, "running")],
      }),
    ).toBe(true);
    expect(
      keepAwakeWanted({
        enabled: true,
        primaryEnvironmentId: local,
        shells: [shell(local, "starting")],
      }),
    ).toBe(true);
  });

  it("releases when every primary thread is idle, stopped or errored", () => {
    expect(
      keepAwakeWanted({
        enabled: true,
        primaryEnvironmentId: local,
        shells: [
          shell(local, "ready"),
          shell(local, "error"),
          shell(local, "stopped"),
          shell(local, null),
        ],
      }),
    ).toBe(false);
  });

  it("ignores remote environments, the setting off, and no primary environment", () => {
    expect(
      keepAwakeWanted({
        enabled: true,
        primaryEnvironmentId: local,
        shells: [shell(remote, "running")],
      }),
    ).toBe(false);
    expect(
      keepAwakeWanted({
        enabled: false,
        primaryEnvironmentId: local,
        shells: [shell(local, "running")],
      }),
    ).toBe(false);
    expect(
      keepAwakeWanted({
        enabled: true,
        primaryEnvironmentId: null,
        shells: [shell(local, "running")],
      }),
    ).toBe(false);
  });
});
