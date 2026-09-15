import { describe, expect, it } from "vite-plus/test";

import {
  affinityInput,
  affinitySupported,
  connectionTestInput,
  connectionTestLine,
  engineSecretInput,
  engineSecretsSupported,
  parseConnectionTest,
  parseProxyEngineState,
  PROXY_ENGINES,
  routingInput,
  routingNotes,
  routingSupported,
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
      routingStrategy: null,
      sessionAffinity: null,
      caveat: null,
      dashboardURL: null,
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
      routingStrategy: null,
      sessionAffinity: null,
      caveat: null,
      dashboardURL: null,
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

describe("testConnectionSupported", () => {
  it("needs the manifest to list test-connection", () => {
    expect(testConnectionSupported([...SUPPORTED, command("test-connection")])).toBe(true);
    expect(testConnectionSupported(SUPPORTED)).toBe(false);
  });
});

describe("connectionTestInput", () => {
  it("names the engine as the positional and the typed url as --url", () => {
    expect(connectionTestInput("9router", " http://10.0.0.5:20128 ")).toEqual({
      command: "test-connection",
      args: ["9router"],
      options: { url: "http://10.0.0.5:20128" },
    });
  });

  it("probes the stored url when the field is blank", () => {
    expect(connectionTestInput("cliproxy", "  ")).toEqual({
      command: "test-connection",
      args: ["cliproxy"],
      options: {},
    });
  });
});

describe("parseConnectionTest", () => {
  it("reads a reached reply with its round trip and version", () => {
    expect(parseConnectionTest({ ok: true, latencyMs: 12, version: "1.4.0" })).toEqual({
      ok: true,
      latencyMs: 12,
      version: "1.4.0",
    });
  });

  it("reads a failed reply with the engine's words", () => {
    expect(parseConnectionTest({ ok: false, error: "connection refused" })).toEqual({
      ok: false,
      error: "connection refused",
    });
  });

  it("is null for a shape it cannot read", () => {
    expect(parseConnectionTest({ reached: true })).toBeNull();
    expect(parseConnectionTest(null)).toBeNull();
  });
});

describe("connectionTestLine", () => {
  it("words a reach with the round trip, the version when the engine says one", () => {
    expect(connectionTestLine({ ok: true, latencyMs: 12, version: null })).toBe(
      "Reachable in 12 ms.",
    );
    expect(connectionTestLine({ ok: true, latencyMs: 340, version: "1.4.0" })).toBe(
      "Reachable in 340 ms, version 1.4.0.",
    );
  });

  it("is the engine's own sentence on a failure", () => {
    expect(connectionTestLine({ ok: false, error: "connection refused" })).toBe(
      "connection refused",
    );
  });
});

describe("PROXY_ENGINES", () => {
  it("lists the two proxy engines with their verbs", () => {
    expect(PROXY_ENGINES.map((e) => [e.key, e.readVerb, e.secretVerb])).toEqual([
      ["cliproxy", "proxy", "proxy-key"],
      ["9router", "9router", "9router-password"],
    ]);
  });
});

describe("parseProxyEngineState routing fields (#1235)", () => {
  it("carries the proxy's routing strategy, affinity, caveat and either engine's dashboard", () => {
    expect(
      parseProxyEngineState({
        baseURL: "http://127.0.0.1:8317",
        dashboardURL: "http://127.0.0.1:8317/management.html",
        keyPresent: true,
        enabled: true,
        routingStrategy: "round-robin",
        sessionAffinity: false,
        caveat: "two credentials share one org",
      }),
    ).toMatchObject({
      routingStrategy: "round-robin",
      sessionAffinity: false,
      caveat: "two credentials share one org",
      dashboardURL: "http://127.0.0.1:8317/management.html",
    });
    expect(
      parseProxyEngineState({
        baseURL: "http://127.0.0.1:20128",
        dashboardURL: "http://127.0.0.1:20128/dashboard",
        passwordPresent: true,
        enabled: true,
      }),
    ).toMatchObject({ dashboardURL: "http://127.0.0.1:20128/dashboard" });
  });

  it("reads an absent strategy, affinity and dashboard as null, an older build's reply included", () => {
    expect(
      parseProxyEngineState({ baseURL: "http://127.0.0.1:8317", keyPresent: false }),
    ).toMatchObject({
      routingStrategy: null,
      sessionAffinity: null,
      caveat: null,
      dashboardURL: null,
    });
  });
});

describe("routing and affinity verbs (#1235)", () => {
  it("gates each row on its own verb", () => {
    expect(routingSupported([...SUPPORTED, command("proxy-routing")])).toBe(true);
    expect(routingSupported(SUPPORTED)).toBe(false);
    expect(affinitySupported([...SUPPORTED, command("proxy-affinity")])).toBe(true);
    expect(affinitySupported([...SUPPORTED, command("proxy-routing")])).toBe(false);
  });

  it("builds the two write inputs", () => {
    expect(routingInput("weighted-round-robin")).toEqual({
      command: "proxy-routing",
      args: ["weighted-round-robin"],
      options: {},
    });
    expect(affinityInput(true)).toEqual({ command: "proxy-affinity", args: ["on"], options: {} });
    expect(affinityInput(false)).toEqual({ command: "proxy-affinity", args: ["off"], options: {} });
  });
});

describe("routingNotes (#1235, the Mac's RoutingNotes)", () => {
  it("explains each strategy", () => {
    expect(routingNotes("round-robin", true).explainer).toBe(
      "Each request goes to the next credential in turn.",
    );
    expect(routingNotes("weighted-round-robin", true).explainer).toBe(
      "Requests rotate in proportion to each credential's priority.",
    );
    expect(routingNotes(null, null).explainer).toBe("Read from the proxy on the next refresh.");
    expect(routingNotes("fill-first", null).explainer).toContain("consume-first");
  });

  it("says nothing about affinity under fill-first or before the strategy is read", () => {
    expect(routingNotes("fill-first", false).note).toBeNull();
    expect(routingNotes(null, false).note).toBeNull();
  });

  it("warns about a rotating proxy without affinity, naming the YAML when the route is missing", () => {
    expect(routingNotes("round-robin", null).note).toEqual({
      tone: "warn",
      text: expect.stringContaining("no management route for it yet"),
    });
    expect(routingNotes("round-robin", false).note).toEqual({
      tone: "warn",
      text: "Turn on session affinity so a conversation stays on one credential: without it every request lands on a different account and the prompt cache misses.",
    });
    expect(routingNotes("round-robin", true).note).toEqual({
      tone: "muted",
      text: "Under affinity, Switch only steers new sessions; bound ones keep their credential until the TTL lapses.",
    });
  });
});
