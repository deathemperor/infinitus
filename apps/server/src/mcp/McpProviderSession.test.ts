import { describe, expect, it } from "vite-plus/test";
import { withProviderSessionEnvironment } from "./McpProviderSession.ts";

describe("device CLI environment", () => {
  it("preserves provider credentials and commands while routing devices to the owned daemon", () => {
    const environment = withProviderSessionEnvironment(
      { PATH: "/provider/bin:/usr/bin", PROVIDER_KEY: "fixture" },
      {
        agentDeviceEnvironment: {
          PATH: "/t3/device/bin",
          PATH_SEPARATOR: ":",
          AGENT_DEVICE_DAEMON_BASE_URL: "http://127.0.0.1:9000",
          AGENT_DEVICE_DAEMON_AUTH_TOKEN: "fixture-device",
        },
      },
    );
    expect(environment).toEqual({
      PATH: "/t3/device/bin:/provider/bin:/usr/bin",
      PROVIDER_KEY: "fixture",
      AGENT_DEVICE_DAEMON_BASE_URL: "http://127.0.0.1:9000",
      AGENT_DEVICE_DAEMON_AUTH_TOKEN: "fixture-device",
    });
  });

  it("exports the owning thread and environment without granting device access", () => {
    const base = { T3_THREAD_ID: "parent", T3_ENVIRONMENT_ID: "old-host", PROVIDER_KEY: "fixture" };
    expect(
      withProviderSessionEnvironment(base, { threadId: "child", environmentId: "host" }),
    ).toEqual({
      T3_THREAD_ID: "child",
      T3_ENVIRONMENT_ID: "host",
      PROVIDER_KEY: "fixture",
    });
    expect(base.T3_THREAD_ID).toBe("parent");
    expect(
      withProviderSessionEnvironment(base, { threadId: "child" }).T3_ENVIRONMENT_ID,
    ).toBeUndefined();
  });

  it("does not grant CLI access when device access was not supplied", () => {
    const environment = { PATH: "/usr/bin", PROVIDER_KEY: "fixture" };
    expect(withProviderSessionEnvironment(environment, undefined)).toBe(environment);
    expect(withProviderSessionEnvironment(environment, {})).toBe(environment);
  });
});
