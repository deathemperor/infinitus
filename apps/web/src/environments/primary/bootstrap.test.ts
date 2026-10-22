import { EnvironmentId, type ExecutionEnvironmentDescriptor } from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import {
  readPrimaryEnvironmentTarget,
  resolvePrimaryEnvironmentHttpUrl,
  resolveInitialPrimaryEnvironmentDescriptor,
  resetPrimaryEnvironmentDescriptorForTests,
} from ".";
import { installEnvironmentHttpTest } from "../../../test/environmentHttpTest";

const BASE_ENVIRONMENT = {
  environmentId: EnvironmentId.make("environment-local"),
  label: "Local environment",
  platform: {
    os: "darwin",
    arch: "arm64",
  },
  serverVersion: "0.0.0-test",
  capabilities: {
    repositoryIdentity: true,
  },
} satisfies ExecutionEnvironmentDescriptor;

let disposeHttpTest: (() => Promise<void>) | undefined;

async function installDescriptorApi() {
  const testApi = await installEnvironmentHttpTest({
    descriptor: () => Effect.succeed(BASE_ENVIRONMENT),
  });
  disposeHttpTest = testApi.dispose;
  return testApi;
}

function installTestBrowser(url: string) {
  vi.stubGlobal("window", {
    location: new URL(url),
    history: {
      replaceState: vi.fn(),
    },
  });
}

describe("environmentBootstrap", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
    installTestBrowser("http://localhost/");
  });

  afterEach(async () => {
    await disposeHttpTest?.();
    disposeHttpTest = undefined;
    resetPrimaryEnvironmentDescriptorForTests();
    vi.unstubAllEnvs();
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("reuses an in-flight descriptor bootstrap request", async () => {
    const testApi = await installDescriptorApi();

    await Promise.all([
      resolveInitialPrimaryEnvironmentDescriptor(),
      resolveInitialPrimaryEnvironmentDescriptor(),
    ]);

    expect(testApi.calls.descriptor).toBe(1);
  });

  it("uses https descriptor urls when the primary environment uses wss", async () => {
    vi.stubEnv("VITE_HTTP_URL", "https://remote.example.com");
    vi.stubEnv("VITE_WS_URL", "wss://remote.example.com");
    await installDescriptorApi();

    await expect(resolveInitialPrimaryEnvironmentDescriptor()).resolves.toEqual(BASE_ENVIRONMENT);
    expect(resolvePrimaryEnvironmentHttpUrl("/.well-known/t3/environment")).toBe(
      "https://remote.example.com/.well-known/t3/environment",
    );
  });

  it("keeps an uppercase wss scheme secure when deriving the http url", () => {
    vi.stubEnv("VITE_WS_URL", "WSS://remote.example.com");

    expect(readPrimaryEnvironmentTarget()?.target).toEqual({
      httpBaseUrl: "https://remote.example.com/",
      wsBaseUrl: "wss://remote.example.com/",
    });
  });

  it("keeps an uppercase https scheme secure when deriving the websocket url", () => {
    vi.stubEnv("VITE_HTTP_URL", "HTTPS://remote.example.com");

    expect(readPrimaryEnvironmentTarget()?.target).toEqual({
      httpBaseUrl: "https://remote.example.com/",
      wsBaseUrl: "wss://remote.example.com/",
    });
  });

  it("uses the vite proxy for desktop-managed loopback descriptor requests during local dev", async () => {
    vi.stubEnv("VITE_DEV_SERVER_URL", "http://127.0.0.1:5733");
    vi.stubGlobal("window", {
      location: new URL("http://127.0.0.1:5733/"),
      history: {
        replaceState: vi.fn(),
      },
      desktopBridge: {
        getLocalEnvironmentBootstraps: () => [
          {
            id: "primary",
            label: "Windows",
            httpBaseUrl: "http://127.0.0.1:3773",
            wsBaseUrl: "ws://127.0.0.1:3773",
            bootstrapToken: "desktop-bootstrap-token",
          },
        ],
      },
    });
    await installDescriptorApi();

    await expect(resolveInitialPrimaryEnvironmentDescriptor()).resolves.toEqual(BASE_ENVIRONMENT);
    expect(resolvePrimaryEnvironmentHttpUrl("/.well-known/t3/environment")).toBe(
      "http://127.0.0.1:5733/.well-known/t3/environment",
    );
  });
<<<<<<< HEAD

  it("retains the URL parser cause without exposing the configured URL in its message", () => {
    vi.stubEnv("VITE_HTTP_URL", "http://[");

    const error = captureThrown(readPrimaryEnvironmentTarget);

    expect(isPrimaryEnvironmentUrlInvalidError(error)).toBe(true);
    if (!isPrimaryEnvironmentUrlInvalidError(error)) {
      throw new Error("Expected a structured primary environment URL error.");
    }
    expect(error).toMatchObject({
      source: "configured",
      urlKind: "http-base-url",
      message: "Could not parse http-base-url for the configured primary environment target.",
    });
    expect(error.cause).toBeInstanceOf(TypeError);
    expect(error.message).not.toContain("http://[");
  });

  it("describes which desktop bootstrap endpoint is missing", () => {
    vi.stubGlobal("window", {
      location: new URL("http://127.0.0.1:5733/"),
      history: { replaceState: vi.fn() },
      desktopBridge: {
        getLocalEnvironmentBootstraps: () => [
          {
            id: "primary",
            label: "Local environment",
            httpBaseUrl: "http://127.0.0.1:3773",
            bootstrapToken: "desktop-bootstrap-token",
          },
        ],
      },
    });

    const error = captureThrown(readPrimaryEnvironmentTarget);

    expect(isDesktopEnvironmentBootstrapIncompleteError(error)).toBe(true);
    if (!isDesktopEnvironmentBootstrapIncompleteError(error)) {
      throw new Error("Expected a structured desktop bootstrap error.");
    }
    expect(error).toMatchObject({
      hasHttpBaseUrl: true,
      hasWsBaseUrl: false,
      message: "Desktop bootstrap is missing wsBaseUrl for the local environment.",
    });
  });

  it("has no primary target when the desktop local environment is disabled", () => {
    vi.stubGlobal("window", {
      location: new URL("infinitus://app/"),
      desktopBridge: {
        getLocalEnvironmentEnabled: () => false,
        getLocalEnvironmentBootstraps: () => [],
      },
    });

    expect(readPrimaryEnvironmentTarget()).toBeNull();
    expect(getPrimaryKnownEnvironment()).toBeNull();
    expect(() => resolvePrimaryEnvironmentHttpUrl("/api/auth/session")).toThrow(
      "The local environment is disabled.",
    );
  });

  it("preserves an unsupported window-origin protocol", () => {
    vi.stubGlobal("window", {
      location: { origin: "file:///tmp/t3code/" },
      history: { replaceState: vi.fn() },
    });

    const error = captureThrown(readPrimaryEnvironmentTarget);

    expect(isPrimaryEnvironmentProtocolUnsupportedError(error)).toBe(true);
    if (!isPrimaryEnvironmentProtocolUnsupportedError(error)) {
      throw new Error("Expected a structured primary environment protocol error.");
    }
    expect(error).toMatchObject({
      source: "window-origin",
      protocol: "file:",
      message: "The window-origin primary environment target uses unsupported protocol file:.",
    });
  });
=======
>>>>>>> upstream-sync-43879d970-upstream-renamed
});
