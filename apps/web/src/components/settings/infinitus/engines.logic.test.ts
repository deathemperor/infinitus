import { describe, expect, it } from "vite-plus/test";

import {
  engineSecretInput,
  engineSecretsSupported,
  parseProxyEngineState,
  PROXY_ENGINES,
  testConnectionSupported,
} from "./engines.logic";

const command = (name: string, stdin?: string) => ({
  name,
  args: [],
  options: [],
  effect: "read" as const,
  summary: "",
  replyShape: "",
  ...(stdin === undefined ? {} : { stdin }),
});

const SUPPORTED = [
  command("proxy"),
  command("proxy-key", "secret"),
  command("9router"),
  command("9router-password", "secret"),
];

describe("engineSecretsSupported", () => {
  it("needs both read verbs and both secret verbs marked stdin secret", () => {
    expect(engineSecretsSupported(SUPPORTED)).toBe(true);
    expect(engineSecretsSupported(SUPPORTED.filter((c) => c.name !== "9router"))).toBe(false);
  });

  it("refuses a secret verb the manifest does not mark stdin secret (pre-#766)", () => {
    const old = SUPPORTED.map((c) => (c.name === "proxy-key" ? command("proxy-key") : c));
    expect(engineSecretsSupported(old)).toBe(false);
  });
});

describe("parseProxyEngineState", () => {
  it("reads the proxy reply (keyPresent)", () => {
    expect(parseProxyEngineState({ baseURL: "http://127.0.0.1:8317", keyPresent: true })).toEqual({
      baseURL: "http://127.0.0.1:8317",
      secretPresent: true,
      error: null,
    });
  });

  it("reads the 9router reply (passwordPresent, error)", () => {
    expect(
      parseProxyEngineState({
        baseURL: "http://127.0.0.1:20128",
        passwordPresent: false,
        enabled: true,
        error: "connection refused",
      }),
    ).toEqual({
      baseURL: "http://127.0.0.1:20128",
      secretPresent: false,
      error: "connection refused",
    });
  });

  it("is null for a shape it cannot read", () => {
    expect(parseProxyEngineState({ keyPresent: true })).toBeNull();
    expect(parseProxyEngineState("nope")).toBeNull();
  });
});

describe("engineSecretInput", () => {
  it("names the engine's secret verb with the url as its bare option name", () => {
    expect(engineSecretInput("9router", " http://127.0.0.1:20128 ")).toEqual({
      command: "9router-password",
      args: { url: "http://127.0.0.1:20128" },
    });
  });

  it("omits the url when it is blank so the Mac's default applies", () => {
    expect(engineSecretInput("cliproxy", "  ")).toEqual({ command: "proxy-key", args: {} });
  });
});

describe("PROXY_ENGINES / testConnectionSupported", () => {
  it("lists the two proxy engines with their verbs", () => {
    expect(PROXY_ENGINES.map((e) => [e.key, e.readVerb, e.secretVerb])).toEqual([
      ["cliproxy", "proxy", "proxy-key"],
      ["9router", "9router", "9router-password"],
    ]);
  });

  it("is off until the manifest lists test-connection", () => {
    expect(testConnectionSupported(SUPPORTED)).toBe(false);
    expect(testConnectionSupported([...SUPPORTED, command("test-connection")])).toBe(true);
  });
});
