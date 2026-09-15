import { describe, expect, it } from "vite-plus/test";

import { buildEngineStatusRows } from "./panel.logic";

const status = {
  version: "0.5.0-alpha.7",
  sha: "fixture",
  socket: "/tmp/x.sock",
  badge: "",
  playground: false,
  signInRunning: false,
  engines: {
    swapd: {
      enabled: true,
      registered: true,
      binaryPath: "/opt/homebrew/bin/swapd",
      daemon: "backingOff",
    },
    cliproxy: { enabled: true, registered: false, keyPresent: true, error: "401 from the proxy" },
    "9router": { enabled: false, registered: false, keyPresent: false },
  },
};

describe("buildEngineStatusRows (#1235)", () => {
  it("words swapd's daemon state and binary path as the row's detail", () => {
    const swapd = buildEngineStatusRows(status).find((row) => row.key === "swapd")!;
    expect(swapd.detail).toBe("Daemon backing off · /opt/homebrew/bin/swapd");
    expect(swapd.error).toBeNull();
  });

  it("carries an engine's own error verbatim and no detail for a proxy", () => {
    const cliproxy = buildEngineStatusRows(status).find((row) => row.key === "cliproxy")!;
    expect(cliproxy.error).toBe("401 from the proxy");
    expect(cliproxy.detail).toBeNull();
  });

  it("has no detail for an engine that reports neither", () => {
    const nine = buildEngineStatusRows(status).find((row) => row.key === "9router")!;
    expect(nine.detail).toBeNull();
    expect(nine.error).toBeNull();
  });
});
