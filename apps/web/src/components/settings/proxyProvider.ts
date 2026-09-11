import type { ProviderInstanceEnvironmentVariable } from "@t3tools/contracts";

/**
 * Fork: "Route through a proxy" on the Claude Config step of the add-instance
 * wizard. A proxy instance is an ordinary Claude instance whose environment
 * carries ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN and the
 * ANTHROPIC_DEFAULT_*_MODEL slots, with its own CLAUDE_CONFIG_DIR so the
 * subscription login in ~/.claude is left alone.
 */
export const PROXY_PRESETS = [
  { id: "9router", label: "9Router", baseUrl: "http://127.0.0.1:20128/v1" },
  { id: "cliproxyapi", label: "CLIProxyAPI", baseUrl: "http://127.0.0.1:8317/v1" },
  { id: "custom", label: "Custom", baseUrl: "" },
] as const;
export type ProxyPresetId = (typeof PROXY_PRESETS)[number]["id"];

export const PROXY_MODEL_SLOTS = [
  { key: "fable", label: "Fable", variable: "ANTHROPIC_DEFAULT_FABLE_MODEL" },
  { key: "opus", label: "Opus", variable: "ANTHROPIC_DEFAULT_OPUS_MODEL" },
  { key: "sonnet", label: "Sonnet", variable: "ANTHROPIC_DEFAULT_SONNET_MODEL" },
  { key: "haiku", label: "Haiku", variable: "ANTHROPIC_DEFAULT_HAIKU_MODEL" },
] as const;
export type ProxyModelSlotKey = (typeof PROXY_MODEL_SLOTS)[number]["key"];

export interface ProxyDraft {
  readonly enabled: boolean;
  readonly preset: ProxyPresetId;
  readonly baseUrl: string;
  readonly apiKey: string;
  readonly slots: Readonly<Record<ProxyModelSlotKey, string>>;
  /** A router model to list in this instance's model picker (e.g. `kr/gpt-5.6-sol`). */
  readonly pickerModel: string;
}

export const EMPTY_PROXY_DRAFT: ProxyDraft = {
  enabled: false,
  preset: "9router",
  baseUrl: PROXY_PRESETS[0].baseUrl,
  apiKey: "",
  slots: { fable: "", opus: "", sonnet: "", haiku: "" },
  pickerModel: "",
};

/** Picking a preset also resets the URL to its default; Custom keeps what is typed. */
export function withProxyPreset(draft: ProxyDraft, preset: ProxyPresetId): ProxyDraft {
  const baseUrl = PROXY_PRESETS.find((entry) => entry.id === preset)?.baseUrl ?? "";
  return { ...draft, preset, baseUrl: preset === "custom" ? draft.baseUrl : baseUrl };
}

export function validateProxyDraft(draft: ProxyDraft): string | null {
  if (!draft.enabled) return null;
  let url: URL;
  try {
    url = new URL(draft.baseUrl.trim());
  } catch {
    return "Enter the proxy's base URL, e.g. http://127.0.0.1:20128/v1.";
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return "The proxy base URL must start with http:// or https://.";
  }
  if (draft.apiKey.trim().length === 0) return "Enter the proxy's API key.";
  return null;
}

function defaultProxyHomePath(instanceId: string): string {
  return `~/.claude-proxy/${instanceId}`;
}

/**
 * Fold the draft into the instance being created: env vars for the proxy,
 * a dedicated CLAUDE_CONFIG_DIR unless one was typed, and the picker model
 * appended to `customModels`. A disabled draft leaves everything untouched.
 */
export function applyProxyDraft(
  draft: ProxyDraft,
  instanceId: string,
  config: Readonly<Record<string, unknown>>,
): {
  readonly config: Record<string, unknown>;
  readonly environment: ReadonlyArray<ProviderInstanceEnvironmentVariable> | undefined;
} {
  if (!draft.enabled) return { config: { ...config }, environment: undefined };
  const environment: ProviderInstanceEnvironmentVariable[] = [
    { name: "ANTHROPIC_BASE_URL", value: draft.baseUrl.trim(), sensitive: false },
    { name: "ANTHROPIC_AUTH_TOKEN", value: draft.apiKey.trim(), sensitive: true },
  ];
  for (const slot of PROXY_MODEL_SLOTS) {
    const model = draft.slots[slot.key].trim();
    if (model.length > 0) environment.push({ name: slot.variable, value: model, sensitive: false });
  }
  const typedHome = typeof config.homePath === "string" ? config.homePath.trim() : "";
  const existingModels = Array.isArray(config.customModels) ? config.customModels : [];
  const pickerModel = draft.pickerModel.trim();
  return {
    config: {
      ...config,
      homePath: typedHome.length > 0 ? typedHome : defaultProxyHomePath(instanceId),
      ...(pickerModel.length > 0 ? { customModels: [...existingModels, pickerModel] } : {}),
    },
    environment,
  };
}
