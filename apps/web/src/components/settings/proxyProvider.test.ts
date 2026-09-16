import type { CustomModelEntry } from "@infinitus/contracts";
import { readCustomModelEntries } from "@infinitus/shared/model";
import { describe, expect, it } from "vite-plus/test";

import {
  applyProxyDraft,
  EMPTY_PROXY_DRAFT,
  proxyAnthropicBaseUrl,
  validateProxyDraft,
  withProxyPreset,
  type ProxyDraft,
} from "./proxyProvider";

const filled: ProxyDraft = {
  ...EMPTY_PROXY_DRAFT,
  enabled: true,
  apiKey: " sk-9r ",
  slots: { fable: "kr/gpt-5.6-sol", opus: "kr/claude-opus-5", sonnet: "", haiku: "" },
  pickerModels: ["kr/gpt-5.6-sol", "kr/claude-opus-5"],
};

describe("proxyProvider", () => {
  it("leaves a plain Claude instance untouched when the proxy is off", () => {
    const result = applyProxyDraft(EMPTY_PROXY_DRAFT, "claudeAgent_work", { homePath: "~/.x" });
    expect(result).toEqual({ config: { homePath: "~/.x" }, environment: undefined });
  });

  it("writes the proxy env vars, marks only the key sensitive, and skips empty slots", () => {
    const { environment } = applyProxyDraft(filled, "claudeAgent_9router", {});
    expect(environment).toEqual([
      { name: "ANTHROPIC_BASE_URL", value: "http://127.0.0.1:20128", sensitive: false },
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

  it("lists the picker models after any custom models already typed", () => {
    expect(applyProxyDraft(filled, "id", { customModels: ["a"] }).config.customModels).toEqual([
      "a",
      { slug: "kr/gpt-5.6-sol", capabilities: expect.anything() },
      { slug: "kr/claude-opus-5", capabilities: expect.anything() },
    ]);
    expect(applyProxyDraft({ ...filled, pickerModels: [] }, "id", {}).config).not.toHaveProperty(
      "customModels",
    );
  });

  it("gives every picked model the Claude effort descriptor, so the composer shows it", () => {
    const [added] = applyProxyDraft({ ...filled, pickerModels: ["kr/x"] }, "id", {}).config
      .customModels as ReadonlyArray<CustomModelEntry>;
    const descriptors = readCustomModelEntries([added])[0]?.capabilities?.optionDescriptors ?? [];
    const effort = descriptors.find((descriptor) => descriptor.id === "effort");
    expect(effort?.type).toBe("select");
    expect(effort?.type === "select" ? effort.options.map((option) => option.id) : []).toEqual([
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]);
    expect(descriptors.find((descriptor) => descriptor.id === "fastMode")?.type).toBe("boolean");
    // The context choice is the only route to 1M on a proxy: the adapter turns
    // a 1M selection into the long-context beta header, since the `[1m]` suffix
    // is what a proxy answers 400 to (#1088). It defaults to 200k.
    const context = descriptors.find((descriptor) => descriptor.id === "contextWindow");
    expect(context?.type === "select" ? context.options : []).toEqual([
      { id: "200k", label: "200k", isDefault: true },
      { id: "1m", label: "1M" },
    ]);
  });

  it("skips picker models the instance already lists, as a slug or an object", () => {
    const config = applyProxyDraft(filled, "id", {
      customModels: ["kr/gpt-5.6-sol", { slug: "kr/claude-opus-5", name: "Opus" }],
    }).config;
    expect(config.customModels).toEqual([
      "kr/gpt-5.6-sol",
      { slug: "kr/claude-opus-5", name: "Opus" },
    ]);
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
    expect(cli.baseUrl).toBe("http://127.0.0.1:8317");
    expect(withProxyPreset(cli, "custom").baseUrl).toBe("http://127.0.0.1:8317");
  });

  it("drops a typed /v1 from the base URL, which the SDK appends itself", () => {
    const typed = { ...filled, preset: "custom", baseUrl: " https://proxy.example/v1/ " } as const;
    const { environment } = applyProxyDraft(typed, "id", {});
    expect(environment?.[0]).toEqual({
      name: "ANTHROPIC_BASE_URL",
      value: "https://proxy.example",
      sensitive: false,
    });
    expect(proxyAnthropicBaseUrl("http://127.0.0.1:8317/")).toBe("http://127.0.0.1:8317");
    // Only the version segment goes; a proxy mounted under a path keeps it.
    expect(proxyAnthropicBaseUrl("https://proxy.example/anthropic")).toBe(
      "https://proxy.example/anthropic",
    );
  });
});
