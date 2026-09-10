import { describe, expect, it } from "vite-plus/test";

import { resolveInfinitusControlSocketPath } from "./infinitusControl.ts";

describe("resolveInfinitusControlSocketPath", () => {
  it("lets the environment override win on every platform", () => {
    expect(
      resolveInfinitusControlSocketPath({
        platform: "darwin",
        env: { INFINITUS_CONTROL_SOCKET: "/tmp/dev.sock" },
        homeDir: "/Users/dev",
      }),
    ).toBe("/tmp/dev.sock");
    expect(
      resolveInfinitusControlSocketPath({
        platform: "win32",
        env: { INFINITUS_CONTROL_SOCKET: "/tmp/dev.sock" },
        homeDir: "C:\\Users\\dev",
      }),
    ).toBe("/tmp/dev.sock");
  });

  it("ignores an empty override and falls back to the platform rule", () => {
    expect(
      resolveInfinitusControlSocketPath({
        platform: "darwin",
        env: { INFINITUS_CONTROL_SOCKET: "" },
        homeDir: "/Users/dev",
      }),
    ).toBe("/Users/dev/Library/Application Support/Infinitus/control/control.sock");
  });

  it("uses Application Support on macOS", () => {
    expect(
      resolveInfinitusControlSocketPath({ platform: "darwin", env: {}, homeDir: "/Users/dev" }),
    ).toBe("/Users/dev/Library/Application Support/Infinitus/control/control.sock");
  });

  it("prefers the XDG runtime dir on Linux", () => {
    expect(
      resolveInfinitusControlSocketPath({
        platform: "linux",
        env: { XDG_RUNTIME_DIR: "/run/user/1000" },
        homeDir: "/home/dev",
      }),
    ).toBe("/run/user/1000/infinitus/control.sock");
  });

  it("falls back to the Linux state dir without a usable runtime dir", () => {
    expect(
      resolveInfinitusControlSocketPath({ platform: "linux", env: {}, homeDir: "/home/dev" }),
    ).toBe("/home/dev/.local/state/infinitus/control.sock");
    expect(
      resolveInfinitusControlSocketPath({
        platform: "linux",
        env: { XDG_RUNTIME_DIR: "" },
        homeDir: "/home/dev",
      }),
    ).toBe("/home/dev/.local/state/infinitus/control.sock");
  });

  it("has no socket on a platform Infinitus does not run on", () => {
    expect(
      resolveInfinitusControlSocketPath({ platform: "win32", env: {}, homeDir: "C:\\Users\\dev" }),
    ).toBeNull();
  });
});
