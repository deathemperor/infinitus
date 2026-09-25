import { useAtomValue } from "@effect/atom-react";
import type { ReactElement } from "react";
import { useId } from "react";

import { APP_STAGE_LABEL } from "../branding";
import { resolveServerBackedAppStageLabel } from "../branding.logic";
import { useTheme } from "../hooks/useTheme";
import { primaryServerConfigAtom } from "../state/server";
import { resolveThemeHalf, themeStageArtScene, type StageArtScene } from "../themePalette";

export type SidebarStageBackdropVariant = StageArtScene;
export type EnvironmentIdentificationPillLabel = "Dev" | "Nightly" | "Alpha";

// A wide viewBox keeps the 96-unit art height at a fixed scale while sidebar resizing reveals
// more horizontal canvas instead of zooming the scene.
const STAGE_BACKDROP_VIEW_BOX = "0 0 8192 96";

/**
 * Which scene the sidebar header draws, if any. The stage label decides whether
 * artwork appears at all; a theme that names a scene decides which one, so the
 * art follows the palette it is drawn from instead of the build's channel.
 */
export function resolveSidebarStageBackdropVariant(
  stageLabel: string,
  enabled = true,
  themeScene: StageArtScene | null = null,
): SidebarStageBackdropVariant | null {
  if (!enabled) return null;
  const normalized = stageLabel.trim().toLowerCase();
  // Fork: the release track draws artwork too. Upstream leaves its stable
  // channel bare because the art is how it marks a prerelease; here every build
  // the user installs is this one, so there is nothing to set it apart from.
  const stageDraws = normalized === "nightly" || normalized === "alpha" || normalized === "dev";
  if (!stageDraws) return null;
  if (themeScene) return themeScene;
  return normalized === "dev" ? "dev" : "nightly";
}

<<<<<<< HEAD
export function resolveSidebarStageFocusRingOffsetClass(
  variant: SidebarStageBackdropVariant,
): string {
  // Every scene but the blueprint is drawn from the night palette.
  return variant === "dev"
    ? "focus-visible:ring-offset-(--stage-art-bottom)"
    : "focus-visible:ring-offset-(--stage-night-bottom)";
}

=======
>>>>>>> upstream-sync-c13f7d93f-upstream-renamed
export function resolveEnvironmentIdentificationPillLabel(
  stageLabel: string,
): EnvironmentIdentificationPillLabel | null {
  const normalized = stageLabel.trim().toLowerCase();
  if (normalized === "dev") return "Dev";
  if (normalized === "nightly") return "Nightly";
  // Fork: the release track has artwork, so it needs the pill as the other way
  // to answer the setting — and the settings row is drawn off this label.
  if (normalized === "alpha") return "Alpha";
  return null;
}

export function useEnvironmentStageLabel(): string {
  const primaryServerVersion =
    useAtomValue(primaryServerConfigAtom)?.environment.serverVersion ?? null;

  return resolveServerBackedAppStageLabel({
    primaryServerVersion,
    fallbackStageLabel: APP_STAGE_LABEL,
  });
}

/** The scene the active theme asks for, or null when it leaves the choice open. */
function useThemeStageArtScene(): StageArtScene | null {
  const { resolvedTheme, theme, themeHalves } = useTheme();
  return themeStageArtScene(resolveThemeHalf(theme, themeHalves, resolvedTheme));
}

export function useSidebarStageBackdropVariant(enabled = true): SidebarStageBackdropVariant | null {
  const stageLabel = useEnvironmentStageLabel();
  const themeScene = useThemeStageArtScene();
  return resolveSidebarStageBackdropVariant(stageLabel, enabled, themeScene);
}

/** Stage-channel header art; palettes mirror the per-channel app icons in `assets/`. */
export function SidebarStageBackdrop({ variant }: { variant: SidebarStageBackdropVariant }) {
  return (
    <div
      aria-hidden
      className="sidebar-stage-backdrop pointer-events-none absolute inset-x-0 top-0 z-0 h-20 select-none overflow-hidden"
    >
      <StageBackdropArt variant={variant} />
    </div>
  );
}

type StageSceneArt = (props: { compact?: boolean }) => ReactElement;

const STAGE_SCENE_ART: Readonly<Record<SidebarStageBackdropVariant, StageSceneArt>> = {
  nightly: NightlySkyArt,
  dev: DevBlueprintArt,
  tide: TideArt,
  dawn: DawnArt,
  nebula: NebulaArt,
};

export function StageBackdropArt({ variant }: { variant: SidebarStageBackdropVariant }) {
  const Art = STAGE_SCENE_ART[variant];
  return <Art />;
}

export function StageBackdropButtonArt({ variant }: { variant: SidebarStageBackdropVariant }) {
  const Art = STAGE_SCENE_ART[variant];
  return <Art compact />;
}

const NIGHTLY_STARS: ReadonlyArray<{
  cx: number;
  cy: number;
  r: number;
  opacity: number;
}> = [
  { cx: 14, cy: 10, r: 0.6, opacity: 0.85 },
  { cx: 38, cy: 22, r: 0.4, opacity: 0.55 },
  { cx: 58, cy: 8, r: 0.5, opacity: 0.7 },
  { cx: 84, cy: 16, r: 0.4, opacity: 0.5 },
  { cx: 104, cy: 7, r: 0.6, opacity: 0.8 },
  { cx: 126, cy: 20, r: 0.4, opacity: 0.55 },
  { cx: 148, cy: 11, r: 0.5, opacity: 0.7 },
  { cx: 170, cy: 24, r: 0.4, opacity: 0.5 },
  { cx: 192, cy: 9, r: 0.6, opacity: 0.8 },
  { cx: 214, cy: 18, r: 0.4, opacity: 0.55 },
  { cx: 236, cy: 8, r: 0.5, opacity: 0.7 },
  { cx: 258, cy: 20, r: 0.45, opacity: 0.6 },
  { cx: 278, cy: 11, r: 0.55, opacity: 0.75 },
  { cx: 26, cy: 34, r: 0.4, opacity: 0.45 },
  { cx: 118, cy: 34, r: 0.4, opacity: 0.45 },
  { cx: 202, cy: 32, r: 0.4, opacity: 0.5 },
  { cx: 268, cy: 34, r: 0.4, opacity: 0.45 },
];

const NIGHTLY_SPARKLES: ReadonlyArray<{ x: number; y: number }> = [
  { x: 70, y: 28 },
  { x: 160, y: 36 },
  { x: 246, y: 26 },
];

function NightlySkyArt({ compact = false }: { compact?: boolean }) {
  const idPrefix = useId().replaceAll(":", "");
  const skyId = `${idPrefix}-stage-night-sky`;
  const glowId = `${idPrefix}-stage-night-glow`;
  const cloudId = `${idPrefix}-stage-night-cloud`;
  const softId = `${idPrefix}-stage-night-soft`;
  const starsId = `${idPrefix}-stage-night-stars`;
  const glowsId = `${idPrefix}-stage-night-glows`;

  return (
    <svg
      data-stage-art="nightly"
      className="h-full w-full"
      fill="none"
      preserveAspectRatio="xMinYMin slice"
      viewBox={compact ? "96 0 8192 96" : STAGE_BACKDROP_VIEW_BOX}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={skyId}
          x1="24"
          y1="0"
          x2="264"
          y2="96"
          gradientUnits="userSpaceOnUse"
          spreadMethod="reflect"
        >
          <stop style={{ stopColor: "var(--stage-night-bottom)" }} />
          <stop offset="0.5" style={{ stopColor: "var(--stage-night-mid)" }} />
          <stop offset="1" style={{ stopColor: "var(--stage-night-top)" }} />
        </linearGradient>
        <radialGradient
          id={glowId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(216 18) rotate(137) scale(120 84)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-night-glow-highlight)" }} stopOpacity="0.4" />
          <stop
            offset="0.5"
            style={{ stopColor: "var(--stage-night-glow-secondary)" }}
            stopOpacity="0.16"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <linearGradient id={cloudId} x1="0" y1="60" x2="288" y2="96" gradientUnits="userSpaceOnUse">
          <stop style={{ stopColor: "var(--stage-night-highlight)" }} stopOpacity="0.5" />
          <stop
            offset="0.52"
            style={{ stopColor: "var(--stage-night-secondary)" }}
            stopOpacity="0.62"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-night-tertiary)" }} stopOpacity="0.5" />
        </linearGradient>
        <filter id={softId} x="-24" y="-24" width="336" height="144" filterUnits="userSpaceOnUse">
          <feGaussianBlur stdDeviation="4" />
        </filter>
        <pattern id={starsId} width="288" height="96" patternUnits="userSpaceOnUse">
          <g style={{ fill: "var(--stage-night-line)" }}>
            {NIGHTLY_STARS.map((star) => (
              <circle
                key={`${star.cx}-${star.cy}`}
                cx={star.cx}
                cy={star.cy}
                r={star.r}
                fillOpacity={star.opacity}
              />
            ))}
          </g>
          <g
            style={{ stroke: "var(--stage-night-sparkle)" }}
            strokeLinecap="round"
            strokeOpacity="0.7"
            strokeWidth="0.6"
          >
            {NIGHTLY_SPARKLES.map((sparkle) => (
              <g key={`${sparkle.x}-${sparkle.y}`}>
                <path d={`M${sparkle.x - 1.5} ${sparkle.y}H${sparkle.x + 1.5}`} />
                <path d={`M${sparkle.x} ${sparkle.y - 1.5}V${sparkle.y + 1.5}`} />
              </g>
            ))}
          </g>
        </pattern>
        <pattern id={glowsId} width="640" height="96" patternUnits="userSpaceOnUse">
          <rect width="640" height="96" fill={`url(#${glowId})`} />
        </pattern>
      </defs>

      <rect width="100%" height="96" fill={`url(#${skyId})`} />
      <rect width="100%" height="96" fill={`url(#${glowsId})`} />
      <rect width="100%" height="96" fill={`url(#${starsId})`} />

      <g filter={`url(#${softId})`}>
        <path
          d="M-12 88C-12 74 0 63 14 63C18 50 30 41 44 41C58 41 70 49 74 62C79 57 86 54 94 54C110 54 123 66 124 82C132 83 138 88 141 96H-12V88Z"
          fill={`url(#${cloudId})`}
        />
      </g>
      <g filter={`url(#${softId})`}>
        <path
          d="M150 96C151 84 161 75 173 75C176 64 186 57 198 57C210 57 220 64 223 75C231 75 238 80 241 87C250 87 257 91 260 96H150Z"
          fill={`url(#${cloudId})`}
          fillOpacity="0.8"
        />
      </g>
    </svg>
  );
}

function DevBlueprintArt({ compact = false }: { compact?: boolean }) {
  const idPrefix = useId().replaceAll(":", "");
  const paperId = `${idPrefix}-stage-bp-paper`;
  const glowId = `${idPrefix}-stage-bp-glow`;
  const celesteGlowId = `${idPrefix}-stage-bp-glow-celeste`;
  const violetGlowId = `${idPrefix}-stage-bp-glow-violet`;
  const minorGridId = `${idPrefix}-stage-bp-grid-minor`;
  const majorGridId = `${idPrefix}-stage-bp-grid-major`;
  const rulerId = `${idPrefix}-stage-bp-ruler`;
  const glowsId = `${idPrefix}-stage-bp-glows`;
  const annotationsId = `${idPrefix}-stage-bp-annotations`;

  return (
    <svg
      data-stage-art="blueprint"
      className="h-full w-full"
      fill="none"
      preserveAspectRatio="xMinYMin slice"
      viewBox={compact ? "64 0 8192 96" : STAGE_BACKDROP_VIEW_BOX}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={paperId}
          x1="60"
          y1="0"
          x2="220"
          y2="96"
          gradientUnits="userSpaceOnUse"
          spreadMethod="reflect"
        >
          <stop style={{ stopColor: "var(--stage-art-bottom)" }} />
          <stop offset="0.5" style={{ stopColor: "var(--stage-art-mid)" }} />
          <stop offset="1" style={{ stopColor: "var(--stage-art-top)" }} />
        </linearGradient>
        <radialGradient
          id={glowId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(216 14) rotate(137) scale(120 84)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-art-highlight)" }} stopOpacity="0.4" />
          <stop
            offset="0.52"
            style={{ stopColor: "var(--stage-art-secondary)" }}
            stopOpacity="0.16"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-art-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <radialGradient
          id={celesteGlowId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(474 44) rotate(166) scale(156 92)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-art-celeste-highlight)" }} stopOpacity="0.34" />
          <stop
            offset="0.5"
            style={{ stopColor: "var(--stage-art-celeste-secondary)" }}
            stopOpacity="0.18"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-art-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <radialGradient
          id={violetGlowId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(704 18) rotate(145) scale(132 88)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-art-violet-highlight)" }} stopOpacity="0.3" />
          <stop
            offset="0.52"
            style={{ stopColor: "var(--stage-art-tertiary)" }}
            stopOpacity="0.14"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-art-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <pattern id={minorGridId} width="8" height="8" patternUnits="userSpaceOnUse">
          <path
            d="M8 0H0V8"
            style={{ stroke: "var(--stage-art-grid-line)" }}
            strokeOpacity="0.14"
            strokeWidth="0.5"
          />
        </pattern>
        <pattern id={majorGridId} width="32" height="32" patternUnits="userSpaceOnUse">
          <path
            d="M32 0H0V32"
            style={{ stroke: "var(--stage-art-grid-line)" }}
            strokeOpacity="0.26"
            strokeWidth="0.6"
          />
        </pattern>
        <pattern id={rulerId} width="32" height="6" patternUnits="userSpaceOnUse">
          <path
            d="M4 0V2.5M12 0V2.5M20 0V4M28 0V2.5"
            style={{ stroke: "var(--stage-art-line)" }}
            strokeOpacity="0.5"
            strokeWidth="0.5"
          />
        </pattern>
        <pattern id={glowsId} width="768" height="96" patternUnits="userSpaceOnUse">
          <rect width="768" height="96" fill={`url(#${glowId})`} />
          <rect width="768" height="96" fill={`url(#${celesteGlowId})`} />
          <rect width="768" height="96" fill={`url(#${violetGlowId})`} />
        </pattern>
        <pattern id={annotationsId} width="768" height="96" patternUnits="userSpaceOnUse">
          <g
            style={{ stroke: "var(--stage-art-line)" }}
            strokeLinecap="round"
            strokeOpacity="0.6"
            strokeWidth="0.7"
          >
            <path d="M180 64H264" strokeDasharray="5 4" />
            <path d="M180 61V67M264 61V67" />
            <path d="M276 10V44" strokeDasharray="4 4" strokeOpacity="0.5" />
            <path d="M273 10H279M273 44H279" strokeOpacity="0.5" />
            <path d="M348 30H428" strokeDasharray="3.5 5" strokeOpacity="0.5" />
            <path d="M348 27V33M428 27V33" strokeOpacity="0.5" />
            <path d="M512 48V80" strokeDasharray="5 3" strokeOpacity="0.45" />
            <path d="M509 48H515M509 80H515" strokeOpacity="0.45" />
            <path d="M590 70H724" strokeDasharray="7 4" strokeOpacity="0.55" />
            <path d="M590 67V73M724 67V73" strokeOpacity="0.55" />
          </g>

          <g
            style={{ stroke: "var(--stage-art-line)" }}
            strokeLinecap="round"
            strokeOpacity="0.55"
            strokeWidth="0.6"
          >
            <g>
              <path d="M34 60L38 64M38 60L34 64" />
            </g>
            <g>
              <path d="M228 26H234M231 23V29" />
            </g>
            <g>
              <path d="M143 51H149M146 48V54" />
            </g>
            <g>
              <path d="M316 16L322 22M322 16L316 22" />
            </g>
            <g>
              <path d="M468 70H476M472 66V74" />
            </g>
            <g>
              <path d="M558 28L564 34M564 28L558 34" />
            </g>
            <g>
              <path d="M742 44H750M746 40V48" />
            </g>
          </g>

          <g style={{ stroke: "var(--stage-art-line)" }} strokeOpacity="0.35" strokeWidth="0.6">
            <circle cx="196" cy="38" r="13" strokeDasharray="3.5 4" />
            <path d="M196 33V43M191 38H201" strokeOpacity="0.6" strokeWidth="0.4" />
            <circle cx="414" cy="64" r="10" strokeDasharray="2.5 3.5" />
            <path d="M414 60V68M410 64H418" strokeOpacity="0.6" strokeWidth="0.4" />
            <circle cx="648" cy="32" r="15" strokeDasharray="4 5" />
            <path d="M648 26V38M642 32H654" strokeOpacity="0.6" strokeWidth="0.4" />
          </g>
        </pattern>
      </defs>

      <rect width="100%" height="96" fill={`url(#${paperId})`} />
      <rect width="100%" height="96" fill={`url(#${glowsId})`} />
      <rect width="100%" height="96" fill={`url(#${minorGridId})`} />
      <rect width="100%" height="96" fill={`url(#${majorGridId})`} />
      <rect width="100%" height="6" fill={`url(#${rulerId})`} />
      <rect width="100%" height="96" fill={`url(#${annotationsId})`} />
    </svg>
  );
}

// Raised into the top half: the container is masked to transparent from 55%
// down, so a swell below y≈53 never renders.
const TIDE_WAVES: ReadonlyArray<{ y: number; amplitude: number; opacity: number }> = [
  { y: 40, amplitude: 5, opacity: 0.42 },
  { y: 48, amplitude: 7, opacity: 0.56 },
  { y: 55, amplitude: 6, opacity: 0.7 },
  { y: 63, amplitude: 8, opacity: 0.84 },
];

function tideWavePath(y: number, amplitude: number): string {
  const segments: Array<string> = [`M0 ${y}`];
  for (let x = 0; x < 288; x += 72) {
    segments.push(`C${x + 18} ${y - amplitude} ${x + 54} ${y + amplitude} ${x + 72} ${y}`);
  }
  segments.push("V96H0Z");
  return segments.join(" ");
}

/** Ocean: stacked swells under a horizon glow. */
function TideArt({ compact = false }: { compact?: boolean }) {
  const idPrefix = useId().replaceAll(":", "");
  const skyId = `${idPrefix}-stage-tide-sky`;
  const glowId = `${idPrefix}-stage-tide-glow`;
  const waveId = `${idPrefix}-stage-tide-wave`;
  const glowsId = `${idPrefix}-stage-tide-glows`;
  const wavesId = `${idPrefix}-stage-tide-waves`;

  return (
    <svg
      className="stage-art stage-tide h-full w-full"
      fill="none"
      preserveAspectRatio="xMinYMin slice"
      viewBox={compact ? "96 0 8192 96" : STAGE_BACKDROP_VIEW_BOX}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={skyId}
          x1="24"
          y1="0"
          x2="264"
          y2="96"
          gradientUnits="userSpaceOnUse"
          spreadMethod="reflect"
        >
          <stop style={{ stopColor: "var(--stage-night-top)" }} />
          <stop offset="0.5" style={{ stopColor: "var(--stage-night-mid)" }} />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} />
        </linearGradient>
        <radialGradient
          id={glowId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(150 42) rotate(180) scale(104 26)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-night-glow-highlight)" }} stopOpacity="0.6" />
          <stop
            offset="0.6"
            style={{ stopColor: "var(--stage-night-glow-secondary)" }}
            stopOpacity="0.14"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <linearGradient id={waveId} x1="0" y1="40" x2="0" y2="96" gradientUnits="userSpaceOnUse">
          <stop style={{ stopColor: "var(--stage-night-highlight)" }} stopOpacity="0.82" />
          <stop offset="1" style={{ stopColor: "var(--stage-night-secondary)" }} stopOpacity="1" />
        </linearGradient>
        <pattern id={glowsId} width="576" height="96" patternUnits="userSpaceOnUse">
          <rect width="576" height="96" fill={`url(#${glowId})`} />
        </pattern>
        <pattern id={wavesId} width="288" height="96" patternUnits="userSpaceOnUse">
          {TIDE_WAVES.map((wave) => (
            <path
              key={wave.y}
              d={tideWavePath(wave.y, wave.amplitude)}
              fill={`url(#${waveId})`}
              fillOpacity={wave.opacity}
            />
          ))}
          <g
            style={{ stroke: "var(--stage-night-line)" }}
            strokeLinecap="round"
            strokeOpacity="0.4"
            strokeWidth="0.5"
          >
            <path d="M28 45H62" />
            <path d="M104 53H150" />
            <path d="M196 47H228" />
            <path d="M242 60H272" />
          </g>
        </pattern>
      </defs>

      <rect width="100%" height="96" fill={`url(#${skyId})`} />
      <rect width="100%" height="96" fill={`url(#${glowsId})`} />
      <rect width="100%" height="96" fill={`url(#${wavesId})`} />
    </svg>
  );
}

// Lifted for the same masking reason as the tide's swells. Generated rather
// than hand-written so each ridge starts and ends at the same y: a tile whose
// two ends disagree steps at every repeat, which reads as a vertical seam.
function dawnRidgePath(y: number, rise: number): string {
  const segments: Array<string> = [`M0 ${y}`];
  for (let x = 0; x < 288; x += 96) {
    segments.push(`C${x + 24} ${y - rise} ${x + 48} ${y - rise * 0.4} ${x + 96} ${y}`);
  }
  segments.push("V96H0Z");
  return segments.join(" ");
}

const DAWN_RIDGES: ReadonlyArray<{ y: number; rise: number; opacity: number }> = [
  { y: 50, rise: 13, opacity: 0.5 },
  { y: 60, rise: 10, opacity: 0.7 },
  { y: 70, rise: 8, opacity: 0.9 },
];

/** Ember: a low sun behind layered ridges. */
function DawnArt({ compact = false }: { compact?: boolean }) {
  const idPrefix = useId().replaceAll(":", "");
  const skyId = `${idPrefix}-stage-dawn-sky`;
  const sunId = `${idPrefix}-stage-dawn-sun`;
  const ridgeId = `${idPrefix}-stage-dawn-ridge`;
  const softId = `${idPrefix}-stage-dawn-soft`;
  const sunsId = `${idPrefix}-stage-dawn-suns`;
  const ridgesId = `${idPrefix}-stage-dawn-ridges`;

  return (
    <svg
      className="stage-art stage-dawn h-full w-full"
      fill="none"
      preserveAspectRatio="xMinYMin slice"
      viewBox={compact ? "96 0 8192 96" : STAGE_BACKDROP_VIEW_BOX}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={skyId}
          x1="24"
          y1="0"
          x2="264"
          y2="96"
          gradientUnits="userSpaceOnUse"
          spreadMethod="reflect"
        >
          <stop style={{ stopColor: "var(--stage-night-top)" }} />
          <stop offset="0.6" style={{ stopColor: "var(--stage-night-mid)" }} />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} />
        </linearGradient>
        <radialGradient
          id={sunId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(210 40) scale(46 46)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-night-highlight)" }} stopOpacity="1" />
          <stop
            offset="0.42"
            style={{ stopColor: "var(--stage-night-secondary)" }}
            stopOpacity="0.34"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <linearGradient id={ridgeId} x1="0" y1="50" x2="0" y2="96" gradientUnits="userSpaceOnUse">
          <stop style={{ stopColor: "var(--stage-night-tertiary)" }} stopOpacity="0.72" />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} stopOpacity="0.95" />
        </linearGradient>
        <filter id={softId} x="-24" y="-24" width="336" height="144" filterUnits="userSpaceOnUse">
          <feGaussianBlur stdDeviation="3" />
        </filter>
        <pattern id={sunsId} width="384" height="96" patternUnits="userSpaceOnUse">
          <rect width="384" height="96" fill={`url(#${sunId})`} />
          <circle
            cx="210"
            cy="40"
            r="7.5"
            style={{ fill: "var(--stage-night-line)" }}
            fillOpacity="0.95"
          />
        </pattern>
        <pattern id={ridgesId} width="288" height="96" patternUnits="userSpaceOnUse">
          {DAWN_RIDGES.map((ridge) => (
            <path
              key={ridge.opacity}
              d={dawnRidgePath(ridge.y, ridge.rise)}
              fill={`url(#${ridgeId})`}
              fillOpacity={ridge.opacity}
            />
          ))}
        </pattern>
      </defs>

      <rect width="100%" height="96" fill={`url(#${skyId})`} />
      <rect width="100%" height="96" fill={`url(#${sunsId})`} />
      {/* Outside the pattern: a filtered shape inside one is clipped to the
          tile, seaming at every repeat. */}
      <g filter={`url(#${softId})`}>
        <circle
          cx="210"
          cy="40"
          r="12"
          style={{ fill: "var(--stage-night-highlight)" }}
          fillOpacity="0.45"
        />
      </g>
      <rect width="100%" height="96" fill={`url(#${ridgesId})`} />
    </svg>
  );
}

const NEBULA_STARS: ReadonlyArray<{ cx: number; cy: number; r: number; opacity: number }> = [
  { cx: 8, cy: 22, r: 0.4, opacity: 0.5 },
  { cx: 12, cy: 14, r: 0.5, opacity: 0.7 },
  { cx: 24, cy: 6, r: 0.45, opacity: 0.6 },
  { cx: 34, cy: 30, r: 0.4, opacity: 0.5 },
  { cx: 43, cy: 20, r: 0.35, opacity: 0.42 },
  { cx: 52, cy: 12, r: 0.6, opacity: 0.8 },
  { cx: 63, cy: 34, r: 0.4, opacity: 0.48 },
  { cx: 71, cy: 26, r: 0.4, opacity: 0.45 },
  { cx: 80, cy: 8, r: 0.5, opacity: 0.68 },
  { cx: 92, cy: 18, r: 0.5, opacity: 0.65 },
  { cx: 101, cy: 28, r: 0.35, opacity: 0.4 },
  { cx: 114, cy: 34, r: 0.45, opacity: 0.55 },
  { cx: 122, cy: 22, r: 0.4, opacity: 0.5 },
  { cx: 132, cy: 10, r: 0.6, opacity: 0.75 },
  { cx: 143, cy: 32, r: 0.35, opacity: 0.42 },
  { cx: 154, cy: 28, r: 0.4, opacity: 0.5 },
  { cx: 163, cy: 6, r: 0.45, opacity: 0.6 },
  { cx: 176, cy: 16, r: 0.55, opacity: 0.7 },
  { cx: 187, cy: 26, r: 0.35, opacity: 0.44 },
  { cx: 198, cy: 32, r: 0.4, opacity: 0.45 },
  { cx: 208, cy: 20, r: 0.4, opacity: 0.52 },
  { cx: 218, cy: 12, r: 0.5, opacity: 0.65 },
  { cx: 229, cy: 34, r: 0.35, opacity: 0.42 },
  { cx: 240, cy: 26, r: 0.45, opacity: 0.55 },
  { cx: 251, cy: 8, r: 0.45, opacity: 0.62 },
  { cx: 262, cy: 18, r: 0.55, opacity: 0.72 },
  { cx: 271, cy: 28, r: 0.35, opacity: 0.44 },
  { cx: 278, cy: 36, r: 0.4, opacity: 0.45 },
  { cx: 284, cy: 14, r: 0.45, opacity: 0.58 },
];

/**
 * One continuous cloud band across the full canvas: repeating a blurred shape
 * needs a long path, since a `<pattern>` would clip the blur at each tile edge
 * (the seam this replaced). Each 288-unit span starts and ends at the same y,
 * so the joins are invisible. Built once, not per render.
 */
function nebulaCloudPath(baseY: number, crest: number): string {
  const span = 288;
  const segments: Array<string> = [`M-8 ${baseY}`];
  for (let x = 0; x < 8192 + span; x += span) {
    segments.push(
      `C${x + 48} ${baseY - crest} ${x + 96} ${baseY - crest * 0.45} ${x + 144} ${baseY - crest * 0.7}`,
      `C${x + 192} ${baseY - crest} ${x + 240} ${baseY - crest * 0.3} ${x + span} ${baseY}`,
    );
  }
  segments.push("V96H-8Z");
  return segments.join(" ");
}

const NEBULA_CLOUD_BACK = nebulaCloudPath(62, 16);
const NEBULA_CLOUD_FRONT = nebulaCloudPath(80, 10);

/** T3 Chat and Iris: banded cloud with a dense star field. */
function NebulaArt({ compact = false }: { compact?: boolean }) {
  const idPrefix = useId().replaceAll(":", "");
  const skyId = `${idPrefix}-stage-nebula-sky`;
  const cloudId = `${idPrefix}-stage-nebula-cloud`;
  const coreId = `${idPrefix}-stage-nebula-core`;
  const softId = `${idPrefix}-stage-nebula-soft`;
  const starsId = `${idPrefix}-stage-nebula-stars`;
  const glowsId = `${idPrefix}-stage-nebula-glows`;

  return (
    <svg
      className="stage-art stage-nebula h-full w-full"
      fill="none"
      preserveAspectRatio="xMinYMin slice"
      viewBox={compact ? "96 0 8192 96" : STAGE_BACKDROP_VIEW_BOX}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient
          id={skyId}
          x1="24"
          y1="0"
          x2="264"
          y2="96"
          gradientUnits="userSpaceOnUse"
          spreadMethod="reflect"
        >
          <stop style={{ stopColor: "var(--stage-night-bottom)" }} />
          <stop offset="0.48" style={{ stopColor: "var(--stage-night-mid)" }} />
          <stop offset="1" style={{ stopColor: "var(--stage-night-top)" }} />
        </linearGradient>
        {/* objectBoundingBox: a user-space 0..288 gradient flat-lined past the
            first span once the band became canvas-wide. */}
        <linearGradient id={cloudId} x1="0" y1="0" x2="0" y2="1">
          <stop style={{ stopColor: "var(--stage-night-tertiary)" }} stopOpacity="0.46" />
          <stop
            offset="0.5"
            style={{ stopColor: "var(--stage-night-secondary)" }}
            stopOpacity="0.6"
          />
          <stop
            offset="1"
            style={{ stopColor: "var(--stage-night-highlight)" }}
            stopOpacity="0.4"
          />
        </linearGradient>
        <radialGradient
          id={coreId}
          cx="0"
          cy="0"
          r="1"
          gradientTransform="translate(126 44) rotate(24) scale(96 40)"
          gradientUnits="userSpaceOnUse"
        >
          <stop style={{ stopColor: "var(--stage-night-glow-highlight)" }} stopOpacity="0.5" />
          <stop
            offset="0.62"
            style={{ stopColor: "var(--stage-night-glow-secondary)" }}
            stopOpacity="0.18"
          />
          <stop offset="1" style={{ stopColor: "var(--stage-night-bottom)" }} stopOpacity="0" />
        </radialGradient>
        <filter id={softId} x="-32" y="-32" width="8256" height="160" filterUnits="userSpaceOnUse">
          <feGaussianBlur stdDeviation="7" />
        </filter>
        <pattern id={starsId} width="288" height="96" patternUnits="userSpaceOnUse">
          <g style={{ fill: "var(--stage-night-line)" }}>
            {NEBULA_STARS.map((star) => (
              <circle
                key={`${star.cx}-${star.cy}`}
                cx={star.cx}
                cy={star.cy}
                r={star.r}
                fillOpacity={star.opacity}
              />
            ))}
          </g>
          <g
            style={{ stroke: "var(--stage-night-sparkle)" }}
            strokeLinecap="round"
            strokeOpacity="0.6"
            strokeWidth="0.55"
          >
            <path d="M62 44H68M65 41V47" />
            <path d="M206 52H212M209 49V55" />
            <path d="M28 14H33M30.5 11.5V16.5" />
            <path d="M146 20H151M148.5 17.5V22.5" />
            <path d="M250 38H255M252.5 35.5V40.5" />
          </g>
        </pattern>
        <pattern id={glowsId} width="576" height="96" patternUnits="userSpaceOnUse">
          <rect width="576" height="96" fill={`url(#${coreId})`} />
        </pattern>
      </defs>

      <rect width="100%" height="96" fill={`url(#${skyId})`} />
      <rect width="100%" height="96" fill={`url(#${glowsId})`} />
      <rect width="100%" height="96" fill={`url(#${starsId})`} />

      {/* Outside every pattern: a blurred band drawn in a <pattern> is clipped
          to its tile, which put a hard seam at each repeat. */}
      <g filter={`url(#${softId})`}>
        <path d={NEBULA_CLOUD_BACK} fill={`url(#${cloudId})`} />
      </g>
      <g filter={`url(#${softId})`}>
        <path d={NEBULA_CLOUD_FRONT} fill={`url(#${cloudId})`} fillOpacity="0.7" />
      </g>
    </svg>
  );
}
