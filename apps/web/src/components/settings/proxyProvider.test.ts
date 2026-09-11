import { describe, expect, it } from "vitest";

import {
  applyProxyDraft,
  EMPTY_PROXY_DRAFT,
  validateProxyDraft,
  withProxyPreset,
  type ProxyDraft,
} from "./proxyProvider";

const filled: ProxyDraft = {
  ...EMPTY_PROXY_DRAFT,
  enabled: true,
  apiKey: " sk-9r ",
  slots: { fable: "kr/gpt-5.6-sol", opus: "kr/claude-opus-5", sonnet: "", haiku: "" },
  pickerModel: "kr/gpt-5.6-sol",
};

describe("proxyProvider", () => {
  it("leaves a plain Claude instance untouched when the proxy is off", () => {
    const result = applyProxyDraft(EMPTY_PROXY_DRAFT, "claudeAgent_work", { homePath: "~/.x" });
    expect(result).toEqual({ config: { homePath: "~/.x" }, environment: undefined });
  });

  it("writes the proxy env vars, marks only the key sensitive, and skips empty slots", () => {
    const { environment } = applyProxyDraft(filled, "claudeAgent_9router", {});
    expect(environment).toEqual([
      { name: "ANTHROPIC_BASE_URL", value: "http://127.0.0.1:20128/v1", sensitive: false },
      { name: "ANTHROPIC_AUTH_TOKEN", value: "sk-9r", sensitive: true },
      { name: "ANTHROPIC_DEFAULT_FABLE_MODEL", value: "kr/gpt-5.6-sol", sensitive: false },
      { name: "ANTHROPIC_DEFAULT_OPUS_MODEL", value: "kr/claude-opus-5", sensitive: false },
    ]);
  });

  it("gives the instance its own config dir unless one was typed", () => {
    expect(applyProxyDraft(filled, "claudeAgent_9router", {}).config.homePath).toBe(
      "~/.claude-proxy/claudeAgent_9router",
    );
    expect(
      applyProxyDraft(filled, "claudeAgent_9router", { homePath: "~/.claude2" }).config.homePath,
    ).toBe("~/.claude2");
  });

  it("lists the picker model after any custom models already typed", () => {
    expect(applyProxyDraft(filled, "id", { customModels: ["a"] }).config.customModels).toEqual([
      "a",
      "kr/gpt-5.6-sol",
    ]);
    expect(applyProxyDraft({ ...filled, pickerModel: "" }, "id", {}).config).not.toHaveProperty(
      "customModels",
    );
  });

  it("validates only when enabled: URL scheme, then key", () => {
    expect(validateProxyDraft(EMPTY_PROXY_DRAFT)).toBeNull();
    expect(validateProxyDraft({ ...filled, baseUrl: "127.0.0.1:20128" })).toMatch(/base URL/);
    expect(validateProxyDraft({ ...filled, baseUrl: "ftp://x" })).toMatch(/http/);
    expect(validateProxyDraft({ ...filled, apiKey: "  " })).toMatch(/API key/);
    expect(validateProxyDraft(filled)).toBeNull();
  });

  it("swaps the URL with the preset but keeps a typed one under Custom", () => {
    const cli = withProxyPreset(filled, "cliproxyapi");
    expect(cli.baseUrl).toBe("http://127.0.0.1:8317/v1");
    expect(withProxyPreset(cli, "custom").baseUrl).toBe("http://127.0.0.1:8317/v1");
  });
});
