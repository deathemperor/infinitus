import { HStack, Image, ProgressView, Spacer, Text, VStack } from "@expo/ui/swift-ui";
import {
  font,
  foregroundStyle,
  frame,
  lineLimit,
  monospacedDigit,
  padding,
  tint,
} from "@expo/ui/swift-ui/modifiers";
import type { InfinitusWorkingActivityState } from "@t3tools/contracts/infinitus";
import {
  createLiveActivity,
  type LiveActivityComponent,
  type LiveActivityLayout,
} from "expo-widgets";

type LiveActivityEnvironment = Parameters<LiveActivityComponent<InfinitusWorkingActivityState>>[1];

/** The Mac's push-to-start / update `content-state.name` for this card. */
export const INFINITUS_WORKING_ACTIVITY_NAME = "InfinitusWorking";

// Serialized into the widget extension's JS bundle: self-contained, no
// module-scope helpers. Props are native's WorkingActivityState verbatim —
// pre-themed labels, colour names and dense reset strings; this only draws.
export function InfinitusWorking(
  props: InfinitusWorkingActivityState,
  environment: LiveActivityEnvironment,
): LiveActivityLayout {
  "widget";

  const primary = "primary";
  const secondary = "secondary";
  const isLight = environment.colorScheme === "light";
  // A window's bar reads by how full it is, not by the theme's colour name
  // (which the widget cannot resolve): sky, amber past 70 %, red past 90 %.
  const barTint = (pct: number): string => {
    if (environment.isLuminanceReduced) return secondary;
    if (pct >= 0.9) return isLight ? "#dc2626" : "#fca5a5";
    if (pct >= 0.7) return isLight ? "#d97706" : "#fcd34d";
    return isLight ? "#0284c7" : "#7dd3fc";
  };
  const percent = (pct: number): string => `${Math.round(Math.min(1, Math.max(0, pct)) * 100)}%`;

  const windows = props.windows;
  const binding =
    props.binding !== null && props.binding !== undefined ? windows[props.binding] : undefined;
  const tightest = binding ?? windows[0];
  const accent = tightest ? barTint(tightest.pct) : isLight ? "#0284c7" : "#7dd3fc";
  const sessions =
    props.total === 0
      ? "no sessions"
      : `${props.busy}/${props.total} busy${props.waiting > 0 ? ` · ${props.waiting} waiting` : ""}`;
  const rate =
    props.tokensPerMinute !== null && props.tokensPerMinute !== undefined
      ? `${props.tokensPerMinute} ${props.rateLabel ?? "tok/min"}`
      : null;
  const w0 = windows[0];
  const w1 = windows[1];
  const w2 = windows[2];

  const renderWindow = (window: { label: string; pct: number; reset?: string | null }) => (
    <HStack spacing={8} alignment="center">
      <Text
        modifiers={[
          font({ weight: "semibold", size: 11 }),
          foregroundStyle(secondary),
          frame({ width: 30, alignment: "leading" }),
          lineLimit(1),
        ]}
      >
        {window.label}
      </Text>
      <ProgressView
        value={Math.min(1, Math.max(0, window.pct))}
        modifiers={[tint(barTint(window.pct))]}
      />
      <Text
        modifiers={[
          font({ weight: "semibold", size: 11 }),
          foregroundStyle(barTint(window.pct)),
          monospacedDigit(),
          frame({ width: 36, alignment: "trailing" }),
        ]}
      >
        {percent(window.pct)}
      </Text>
      {window.reset ? (
        <Text
          modifiers={[
            font({ size: 11 }),
            foregroundStyle(secondary),
            monospacedDigit(),
            lineLimit(1),
          ]}
        >
          {window.reset}
        </Text>
      ) : null}
    </HStack>
  );

  const header = (
    <HStack spacing={6} alignment="center">
      <Image
        systemName="bolt.fill"
        modifiers={[frame({ width: 13, height: 13 }), foregroundStyle(accent)]}
      />
      <Text
        modifiers={[font({ weight: "semibold", size: 13 }), foregroundStyle(primary), lineLimit(1)]}
      >
        {props.active}
      </Text>
      {props.plan ? (
        <Text modifiers={[font({ size: 12 }), foregroundStyle(secondary), lineLimit(1)]}>
          {props.plan}
        </Text>
      ) : null}
      <Spacer minLength={0} />
      <Text
        modifiers={[
          font({ size: 12 }),
          foregroundStyle(secondary),
          monospacedDigit(),
          lineLimit(1),
        ]}
      >
        {sessions}
      </Text>
    </HStack>
  );

  return {
    banner: (
      <VStack alignment="leading" spacing={6} modifiers={[padding({ all: 14 })]}>
        {header}
        {w0 ? renderWindow(w0) : null}
        {w1 ? renderWindow(w1) : null}
        {w2 ? renderWindow(w2) : null}
        {props.next || rate ? (
          <HStack spacing={6} alignment="center">
            {props.next ? (
              <Text
                modifiers={[font({ size: 11 }), foregroundStyle(secondary), lineLimit(1)]}
              >{`next: ${props.next}`}</Text>
            ) : null}
            <Spacer minLength={0} />
            {rate ? (
              <Text
                modifiers={[
                  font({ size: 11 }),
                  foregroundStyle(secondary),
                  monospacedDigit(),
                  lineLimit(1),
                ]}
              >
                {rate}
              </Text>
            ) : null}
          </HStack>
        ) : null}
      </VStack>
    ),
    bannerSmall: (
      <VStack alignment="leading" spacing={5} modifiers={[padding({ all: 10 })]}>
        <HStack spacing={6} alignment="center">
          <Image
            systemName="bolt.fill"
            modifiers={[frame({ width: 13, height: 13 }), foregroundStyle(accent)]}
          />
          <Text
            modifiers={[font({ weight: "bold", size: 13 }), foregroundStyle(primary), lineLimit(1)]}
          >
            {props.active}
          </Text>
        </HStack>
        {tightest ? renderWindow(tightest) : null}
        <Text modifiers={[font({ size: 11 }), foregroundStyle(secondary), lineLimit(1)]}>
          {sessions}
        </Text>
      </VStack>
    ),
    compactLeading: (
      <Image
        systemName="bolt.fill"
        modifiers={[frame({ width: 12, height: 12 }), foregroundStyle(accent)]}
      />
    ),
    compactTrailing: (
      <Text
        modifiers={[
          font({ weight: "semibold", size: 11 }),
          foregroundStyle(accent),
          monospacedDigit(),
        ]}
      >
        {tightest ? percent(tightest.pct) : props.slot}
      </Text>
    ),
    minimal: (
      <Text
        modifiers={[
          font({ weight: "semibold", size: 10 }),
          foregroundStyle(accent),
          monospacedDigit(),
        ]}
      >
        {tightest ? percent(tightest.pct) : "∞"}
      </Text>
    ),
    expandedLeading: (
      <HStack spacing={5} alignment="center" modifiers={[padding({ leading: 4, vertical: 4 })]}>
        <Image
          systemName="bolt.fill"
          modifiers={[frame({ width: 13, height: 13 }), foregroundStyle(accent)]}
        />
        <Text
          modifiers={[font({ weight: "bold", size: 13 }), foregroundStyle(primary), lineLimit(1)]}
        >
          {props.active}
        </Text>
      </HStack>
    ),
    expandedCenter: null,
    expandedTrailing: (
      <Text
        modifiers={[
          font({ size: 12 }),
          foregroundStyle(secondary),
          monospacedDigit(),
          padding({ trailing: 4, vertical: 4 }),
        ]}
      >
        {sessions}
      </Text>
    ),
    expandedBottom: (
      <VStack alignment="leading" spacing={5} modifiers={[padding({ vertical: 2, horizontal: 8 })]}>
        {w0 ? renderWindow(w0) : null}
        {w1 ? renderWindow(w1) : null}
      </VStack>
    ),
  };
}

export default createLiveActivity<InfinitusWorkingActivityState>(
  INFINITUS_WORKING_ACTIVITY_NAME,
  InfinitusWorking,
);
