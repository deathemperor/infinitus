import type {
  BackgroundActivityProfile,
  BackgroundActivitySettings,
  ProviderDriverKind,
  ProviderInstanceConfig,
  PreviewViewportSetting,
  ProviderInstanceId,
  ServerSettings,
  SidebarProjectGroupingMode,
  UnifiedSettings,
} from "@infinitus/contracts";
<<<<<<< HEAD
import type { DesktopUpdateChannel } from "@infinitus/contracts";
=======
>>>>>>> upstream-sync-7445aa733-upstream-renamed
import { DEFAULT_UNIFIED_SETTINGS } from "@infinitus/contracts/settings";
import {
  getBackgroundActivityBaseProfile,
  normalizeBackgroundActivitySettings,
  normalizeServerBackgroundActivitySettings,
  resolveServerBackgroundActivitySettings,
} from "@infinitus/shared/backgroundActivitySettings";
<<<<<<< HEAD
import { PRODUCT_NAME } from "@infinitus/shared/productName";
=======
>>>>>>> upstream-sync-7445aa733-upstream-renamed
import * as Duration from "effect/Duration";
import * as Equal from "effect/Equal";

export function isProjectGroupingEnabled(mode: SidebarProjectGroupingMode): boolean {
  return mode !== "separate";
}

export function projectGroupingModeFromToggle(
  enabled: boolean,
  lastEnabledMode: SidebarProjectGroupingMode = "repository",
): SidebarProjectGroupingMode {
  if (!enabled) return "separate";
  return lastEnabledMode === "repository_path" ? "repository_path" : "repository";
}

const LAST_ENABLED_PROJECT_GROUPING_MODE_KEY = "t3code:last-enabled-project-grouping-mode";

export function readLastEnabledProjectGroupingMode(): SidebarProjectGroupingMode {
  try {
    return localStorage.getItem(LAST_ENABLED_PROJECT_GROUPING_MODE_KEY) === "repository_path"
      ? "repository_path"
      : "repository";
  } catch {
    return "repository";
  }
}

export function rememberEnabledProjectGroupingMode(mode: SidebarProjectGroupingMode): void {
  if (mode === "separate") return;
  try {
    localStorage.setItem(LAST_ENABLED_PROJECT_GROUPING_MODE_KEY, mode);
  } catch {
    // Storage can be unavailable in restricted browser contexts.
  }
}

export function hasChangedBackgroundActivitySettings(
  settings: Pick<
    UnifiedSettings,
    | "backgroundActivity"
    | "backgroundActivityProfile"
    | "automaticGitFetchInterval"
    | "providerHealthRefreshInterval"
  >,
): boolean {
  return (
    !Equal.equals(settings.backgroundActivity, DEFAULT_UNIFIED_SETTINGS.backgroundActivity) ||
    settings.backgroundActivityProfile !== DEFAULT_UNIFIED_SETTINGS.backgroundActivityProfile ||
    !Equal.equals(
      settings.automaticGitFetchInterval,
      DEFAULT_UNIFIED_SETTINGS.automaticGitFetchInterval,
    ) ||
    !Equal.equals(
      settings.providerHealthRefreshInterval,
      DEFAULT_UNIFIED_SETTINGS.providerHealthRefreshInterval,
    )
  );
}

type TypographySettings = Pick<
  UnifiedSettings,
  | "fontFamilySans"
  | "fontFamilyComposer"
  | "fontFamilyCode"
  | "fontFamilyTerminal"
  | "fontSizeInterface"
  | "fontSizePrompt"
  | "fontSizeCode"
  | "fontSizeTerminal"
>;

/** Labels the font rows whose family or size differs from the defaults. */
export function getChangedTypographySettingLabels(settings: TypographySettings): string[] {
  return [
    ...(settings.fontFamilySans !== DEFAULT_UNIFIED_SETTINGS.fontFamilySans ||
    settings.fontSizeInterface !== DEFAULT_UNIFIED_SETTINGS.fontSizeInterface
      ? ["Interface font"]
      : []),
    ...(settings.fontFamilyComposer !== DEFAULT_UNIFIED_SETTINGS.fontFamilyComposer ||
    settings.fontSizePrompt !== DEFAULT_UNIFIED_SETTINGS.fontSizePrompt
      ? ["Prompt font"]
      : []),
    ...(settings.fontFamilyCode !== DEFAULT_UNIFIED_SETTINGS.fontFamilyCode ||
    settings.fontSizeCode !== DEFAULT_UNIFIED_SETTINGS.fontSizeCode
      ? ["Code font"]
      : []),
    ...(settings.fontFamilyTerminal !== DEFAULT_UNIFIED_SETTINGS.fontFamilyTerminal ||
    settings.fontSizeTerminal !== DEFAULT_UNIFIED_SETTINGS.fontSizeTerminal
      ? ["Terminal font"]
      : []),
  ];
}

export type BrowserDefaultSettings = Pick<
  UnifiedSettings,
  | "browserDefaultViewport"
  | "browserDefaultZoomFactor"
  | "browserDefaultAppearance"
  | "browserRecordingFrameRate"
  | "browserLinkTarget"
  | "browserAutoShowFloatingPreview"
>;

/**
 * True when two viewport settings describe the same viewport.
 *
 * The setting is a tagged union rather than a scalar, so identity comparison
 * reports every stored viewport as changed — including one that matches the
 * default.
 */
function isSamePreviewViewport(
  left: PreviewViewportSetting,
  right: PreviewViewportSetting,
): boolean {
  if (left._tag !== right._tag) return false;
  if (left._tag === "fill" || right._tag === "fill") return true;
  if (left.width !== right.width || left.height !== right.height) return false;
  return left._tag === "preset" && right._tag === "preset"
    ? left.presetId === right.presetId
    : true;
}

/** Labels the browser-default rows that differ from the defaults. */
export function getChangedBrowserSettingLabels(settings: BrowserDefaultSettings): string[] {
  return [
    ...(isSamePreviewViewport(
      settings.browserDefaultViewport,
      DEFAULT_UNIFIED_SETTINGS.browserDefaultViewport,
    )
      ? []
      : ["Browser viewport"]),
    ...(settings.browserDefaultZoomFactor !== DEFAULT_UNIFIED_SETTINGS.browserDefaultZoomFactor
      ? ["Browser zoom"]
      : []),
    ...(settings.browserDefaultAppearance !== DEFAULT_UNIFIED_SETTINGS.browserDefaultAppearance
      ? ["Browser appearance"]
      : []),
    ...(settings.browserRecordingFrameRate !== DEFAULT_UNIFIED_SETTINGS.browserRecordingFrameRate
      ? ["Recording frame rate"]
      : []),
    ...(settings.browserLinkTarget !== DEFAULT_UNIFIED_SETTINGS.browserLinkTarget
      ? ["Open links in"]
      : []),
    ...(settings.browserAutoShowFloatingPreview !==
    DEFAULT_UNIFIED_SETTINGS.browserAutoShowFloatingPreview
      ? ["Floating preview"]
      : []),
  ];
}

export function resolveBackgroundActivityProfileOption(
  settings: ServerSettings,
): BackgroundActivityProfile | "advanced" {
  const resolved = resolveServerBackgroundActivitySettings(settings);
  const normalized = normalizeBackgroundActivitySettings({
    schemaVersion: 1,
    profile: "custom",
    baseProfile: resolved.profile,
    overrides: {
      automaticGitFetchInterval: resolved.automaticGitFetchInterval,
      providerHealthRefreshInterval: resolved.providerHealthRefreshInterval,
      hostPowerMonitorActiveInterval: resolved.hostPowerMonitorActiveInterval,
      hostPowerMonitorIdleInterval: resolved.hostPowerMonitorIdleInterval,
      idleClientTtl: resolved.idleClientTtl,
      pauseWhenHostLocked: resolved.pauseWhenHostLocked,
      pauseWhenHostLowPower: resolved.pauseWhenHostLowPower,
      pauseWhenClientLowPower: resolved.pauseWhenClientLowPower,
      pauseWhenOnBattery: resolved.pauseWhenOnBattery,
    },
  });
  return normalized.profile === "custom" ? "advanced" : normalized.profile;
}

export function backgroundActivitySharedPolicySettings(
  settings: ServerSettings,
  profile: BackgroundActivityProfile,
): BackgroundActivitySettings {
  const normalized = normalizeServerBackgroundActivitySettings(settings);
  return {
    schemaVersion: 1,
    profile: "custom",
    baseProfile: profile,
    overrides: normalized.profile === "custom" ? normalized.overrides : {},
  };
}

function collapseOtelSignalsUrl(input: {
  readonly tracesUrl: string;
  readonly metricsUrl: string;
}): string | null {
  const tracesSuffix = "/traces";
  const metricsSuffix = "/metrics";
  if (!input.tracesUrl.endsWith(tracesSuffix) || !input.metricsUrl.endsWith(metricsSuffix)) {
    return null;
  }

  const tracesBase = input.tracesUrl.slice(0, -tracesSuffix.length);
  const metricsBase = input.metricsUrl.slice(0, -metricsSuffix.length);
  if (tracesBase !== metricsBase) {
    return null;
  }

  return `${tracesBase}/{traces,metrics}`;
}

export function formatDiagnosticsDescription(input: {
  readonly localTracingEnabled: boolean;
  readonly otlpTracesEnabled: boolean;
  readonly otlpTracesUrl?: string | undefined;
  readonly otlpMetricsEnabled: boolean;
  readonly otlpMetricsUrl?: string | undefined;
}): string {
  const mode = input.localTracingEnabled ? "Local trace file" : "Terminal logs only";
  const tracesUrl = input.otlpTracesEnabled ? input.otlpTracesUrl : undefined;
  const metricsUrl = input.otlpMetricsEnabled ? input.otlpMetricsUrl : undefined;

  if (tracesUrl && metricsUrl) {
    const collapsedUrl = collapseOtelSignalsUrl({ tracesUrl, metricsUrl });
    return collapsedUrl
      ? `${mode}. Exporting OTEL to ${collapsedUrl}.`
      : `${mode}. Exporting OTEL traces to ${tracesUrl} and metrics to ${metricsUrl}.`;
  }

  if (tracesUrl) {
    return `${mode}. Exporting OTEL traces to ${tracesUrl}.`;
  }

  if (metricsUrl) {
    return `${mode}. Exporting OTEL metrics to ${metricsUrl}.`;
  }

  return `${mode}.`;
}

export function buildProviderInstanceUpdatePatch(input: {
  readonly settings: Pick<ServerSettings, "providers" | "providerInstances">;
  readonly instanceId: ProviderInstanceId;
  readonly instance: ProviderInstanceConfig;
  readonly driver: ProviderDriverKind;
  readonly isDefault: boolean;
  readonly textGenerationModelSelection?:
    | ServerSettings["textGenerationModelSelection"]
    | undefined;
}): Partial<UnifiedSettings> {
  type LegacyProviderSettings = ServerSettings["providers"][keyof ServerSettings["providers"]];
  const legacyProviderDefaults = DEFAULT_UNIFIED_SETTINGS.providers as Record<
    string,
    LegacyProviderSettings | undefined
  >;
  const legacyProviderDefault = input.isDefault ? legacyProviderDefaults[input.driver] : undefined;
  return {
    ...(legacyProviderDefault !== undefined
      ? {
          providers: {
            ...input.settings.providers,
            [input.driver]: legacyProviderDefault,
          } as ServerSettings["providers"],
        }
      : {}),
    providerInstances: {
      ...input.settings.providerInstances,
      [input.instanceId]: input.instance,
    },
    ...(input.textGenerationModelSelection !== undefined
      ? { textGenerationModelSelection: input.textGenerationModelSelection }
      : {}),
  };
}

// ── Background-activity interval helpers ─────────────────────────────
// Shared by the General panel's interval rows and the Providers panel's
// health-check row.

export const PROVIDER_HEALTH_INTERVAL_STEP_SECONDS = 30;

type BackgroundActivityOverridePatch = Partial<{
  [K in keyof BackgroundActivitySettings["overrides"]]:
    | BackgroundActivitySettings["overrides"][K]
    | undefined;
}>;

export function durationToSeconds(duration: Duration.Duration): number {
  return Math.round(Duration.toMillis(duration) / 1_000);
}

export function normalizeIntervalSeconds(value: number | null, minimum = 0): number {
  if (value === null || !Number.isFinite(value)) {
    return minimum;
  }
  return Math.max(minimum, Math.round(value));
}

export function backgroundActivityOverrideSettings(
  current: BackgroundActivitySettings,
  resolved: ReturnType<typeof resolveServerBackgroundActivitySettings>,
  overrides: BackgroundActivityOverridePatch,
) {
  const nextOverrides: BackgroundActivityOverridePatch = {
    automaticGitFetchInterval: resolved.automaticGitFetchInterval,
    providerHealthRefreshInterval: resolved.providerHealthRefreshInterval,
    hostPowerMonitorActiveInterval: resolved.hostPowerMonitorActiveInterval,
    hostPowerMonitorIdleInterval: resolved.hostPowerMonitorIdleInterval,
    idleClientTtl: resolved.idleClientTtl,
    pauseWhenHostLocked: resolved.pauseWhenHostLocked,
    pauseWhenHostLowPower: resolved.pauseWhenHostLowPower,
    pauseWhenClientLowPower: resolved.pauseWhenClientLowPower,
    pauseWhenOnBattery: resolved.pauseWhenOnBattery,
    ...overrides,
  };
  for (const [key, value] of Object.entries(nextOverrides)) {
    if (value === undefined) {
      delete nextOverrides[key as keyof typeof nextOverrides];
    }
  }
  return {
    backgroundActivity: {
      schemaVersion: 1 as const,
      profile: "custom" as const,
      baseProfile: getBackgroundActivityBaseProfile(current),
      overrides: nextOverrides as BackgroundActivitySettings["overrides"],
    },
  };
}

export interface DesktopUpdateTrackRow {
  readonly label: string;
  readonly description: string;
  /** False keeps the track read-only: there is no track to switch to. */
  readonly switchable: boolean;
  /** The tracks the select offers, the current one among them. */
  readonly options: readonly { readonly value: DesktopUpdateChannel; readonly label: string }[];
}

const UPSTREAM_TRACK_OPTIONS = [
  { value: "latest", label: "Stable" },
  { value: "nightly", label: "Nightly" },
] as const satisfies DesktopUpdateTrackRow["options"];

const INFINITUS_TRACK_OPTIONS = [
  { value: "infinitus", label: "Release" },
  { value: "infinitus-nightly", label: "Nightly" },
] as const satisfies DesktopUpdateTrackRow["options"];

/**
 * The Update-track row of an installed desktop build. A fork build follows the
 * `infinitus` channel, whose releases only this repository publishes, or its
 * nightly (#1042: last night's build of main, every day); upstream's Stable
 * and Nightly tracks would hand it the real T3 Code on the next update, with
 * no way back, so the fork's select offers only its own two.
 */
export function resolveDesktopUpdateTrackRow(
  channel: DesktopUpdateChannel | null,
): DesktopUpdateTrackRow {
  if (channel === null) {
    // The bridge has not reported a track yet (or its read failed). Offering a
    // switch here would let a fork build leave the `infinitus` channel before
    // anything knows it is on it.
    return {
      label: "Checking…",
      description: "Use stable releases or nightly builds. Switch back anytime.",
      switchable: false,
      options: [],
    };
  }
  if (channel === "infinitus" || channel === "infinitus-nightly") {
    return {
      label: channel === "infinitus" ? "Release" : "Nightly",
      description: `Release follows ${PRODUCT_NAME} releases; Nightly is last night's build of main. Switch back anytime.`,
      switchable: true,
      options: INFINITUS_TRACK_OPTIONS,
    };
  }
  return {
    label: channel === "nightly" ? "Nightly" : "Stable",
    description: "Use stable releases or nightly builds. Switch back anytime.",
    switchable: true,
    options: UPSTREAM_TRACK_OPTIONS,
  };
}
