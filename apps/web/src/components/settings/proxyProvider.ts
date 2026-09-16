import type {
  CustomModelSetting,
  ProviderInstanceEnvironmentVariable,
  ProviderOptionDescriptor,
} from "@t3tools/contracts";
import { createModelCapabilities } from "@t3tools/shared/model";

/**
 * Fork: "Route through a proxy" on the Claude Config step of the add-instance
 * wizard. A proxy instance is an ordinary Claude instance whose environment
 * carries ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN and the
 * ANTHROPIC_DEFAULT_*_MODEL slots, with its own CLAUDE_CONFIG_DIR so the
 * subscription login in ~/.claude is left alone.
 */
export const PROXY_PRESETS = [
  { id: "9router", label: "9Router", baseUrl: "http://127.0.0.1:20128" },
  { id: "cliproxyapi", label: "CLIProxyAPI", baseUrl: "http://127.0.0.1:8317" },
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
  /** Router models to list in this instance's model picker (e.g. `kr/gpt-5.6-sol`). */
  readonly pickerModels: ReadonlyArray<string>;
}

export const EMPTY_PROXY_DRAFT: ProxyDraft = {
  enabled: false,
  preset: "9router",
  baseUrl: PROXY_PRESETS[0].baseUrl,
  apiKey: "",
  slots: { fable: "", opus: "", sonnet: "", haiku: "" },
  pickerModels: [],
};

/** Picking a preset also resets the URL to its default; Custom keeps what is typed. */
export function withProxyPreset(draft: ProxyDraft, preset: ProxyPresetId): ProxyDraft {
  const baseUrl = PROXY_PRESETS.find((entry) => entry.id === preset)?.baseUrl ?? "";
  return { ...draft, preset, baseUrl: preset === "custom" ? draft.baseUrl : baseUrl };
}

/**
 * The value `ANTHROPIC_BASE_URL` takes. The Anthropic SDK appends `/v1/messages`
 * to it, so a base URL that already ends in `/v1` would reach `/v1/v1/messages`
 * — 404 on CLIProxyAPI, and a path 9Router only happens to tolerate. Strip it,
 * whether it came from a preset or was typed.
 */
export function proxyAnthropicBaseUrl(baseUrl: string): string {
  return baseUrl.trim().replace(/\/+$/, "").replace(/\/v1$/, "");
}

export function validateProxyDraft(draft: ProxyDraft): string | null {
  if (!draft.enabled) return null;
  let url: URL;
  try {
    url = new URL(draft.baseUrl.trim());
  } catch {
    return "Enter the proxy's base URL, e.g. http://127.0.0.1:20128.";
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

/** The slug of a `customModels` entry, which is a bare string or `{slug}`. */
function customModelSlug(entry: unknown): string | null {
  if (typeof entry === "string") return entry.trim() || null;
  if (entry !== null && typeof entry === "object" && "slug" in entry) {
    const slug = (entry as { slug?: unknown }).slug;
    return typeof slug === "string" ? slug.trim() || null : null;
  }
  return null;
}

/**
 * The descriptors a picked proxy model is stored with. A custom model entry
 * without capabilities gets the Claude driver's empty default, which leaves
 * the composer with no reasoning control at all; writing Claude's own effort
 * descriptor makes the control appear without editing every model by hand.
 * Custom entries carry no runtime effort map, so the chosen value reaches the
 * proxy verbatim as `output_config.effort`. Thinking is a Claude Code setting
 * a proxy upstream need not honour, so it stays off the entry.
 *
 * Context window is here because a proxy is the one place the choice cannot be
 * inferred: the `[1m]` suffix that buys the CLI its 1M window is Anthropic's
 * wire syntax a proxy answers 400 to (#1088), so the adapter sends the
 * long-context beta header instead — but only when the selection resolves 1M,
 * which needs this descriptor to exist. It defaults to 200k: which upstream a
 * proxy slug reaches is the router's business, and a model that cannot serve
 * 1M should not be asked for it by default.
 */
const PROXY_MODEL_OPTION_DESCRIPTORS = [
  {
    id: "effort",
    label: "Reasoning",
    type: "select",
    options: [
      { id: "low", label: "Low" },
      { id: "medium", label: "Medium" },
      { id: "high", label: "High", isDefault: true },
      { id: "xhigh", label: "Extra High" },
      { id: "max", label: "Max" },
    ],
  },
  { id: "fastMode", label: "Fast Mode", type: "boolean" },
  {
    id: "contextWindow",
    label: "Context Window",
    type: "select",
    options: [
      { id: "200k", label: "200k", isDefault: true },
      { id: "1m", label: "1M" },
    ],
  },
] as const satisfies ReadonlyArray<ProviderOptionDescriptor>;

/**
 * Fold the draft into the instance being created: env vars for the proxy,
 * a dedicated CLAUDE_CONFIG_DIR unless one was typed, and the picker models
 * appended to `customModels`. A disabled draft leaves everything untouched.
 */
/** Whether the instance routes Claude through a proxy, which the advisor tool does not cross (#1232). */
export function hasAnthropicBaseUrl(
  environment: ReadonlyArray<ProviderInstanceEnvironmentVariable> | undefined,
): boolean {
  return (environment ?? []).some(
    (variable) => variable.name === "ANTHROPIC_BASE_URL" && variable.value.trim().length > 0,
  );
}

export const PROXY_ADVISOR_NOTE =
  "This instance routes through a proxy, which does not pass the advisor tool through.";

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
    { name: "ANTHROPIC_BASE_URL", value: proxyAnthropicBaseUrl(draft.baseUrl), sensitive: false },
    { name: "ANTHROPIC_AUTH_TOKEN", value: draft.apiKey.trim(), sensitive: true },
  ];
  for (const slot of PROXY_MODEL_SLOTS) {
    const model = draft.slots[slot.key].trim();
    if (model.length > 0) environment.push({ name: slot.variable, value: model, sensitive: false });
  }
  const typedHome = typeof config.homePath === "string" ? config.homePath.trim() : "";
  const existingModels = Array.isArray(config.customModels) ? config.customModels : [];
  const taken = new Set(
    existingModels.map((entry) => customModelSlug(entry)).filter((slug) => slug !== null),
  );
  const added: CustomModelSetting[] = [];
  for (const model of draft.pickerModels) {
    const slug = model.trim();
    if (slug.length === 0 || taken.has(slug)) continue;
    taken.add(slug);
    added.push({
      slug,
      capabilities: createModelCapabilities({
        optionDescriptors: PROXY_MODEL_OPTION_DESCRIPTORS,
      }),
    });
  }
  return {
    config: {
      ...config,
      homePath: typedHome.length > 0 ? typedHome : defaultProxyHomePath(instanceId),
      ...(added.length > 0 ? { customModels: [...existingModels, ...added] } : {}),
    },
    environment,
  };
}
