import { HStack, Image, Spacer, Text, VStack } from "@expo/ui/swift-ui";
import {
  font,
  foregroundStyle,
  frame,
  lineLimit,
  monospacedDigit,
  padding,
} from "@expo/ui/swift-ui/modifiers";
import type { InfinitusRevivalActivityState } from "@t3tools/contracts/infinitus";
import {
  createLiveActivity,
  type LiveActivityComponent,
  type LiveActivityLayout,
} from "expo-widgets";

type LiveActivityEnvironment = Parameters<LiveActivityComponent<InfinitusRevivalActivityState>>[1];

/** The Mac's push-to-start / update `content-state.name` for this card. */
export const INFINITUS_REVIVAL_ACTIVITY_NAME = "InfinitusRevival";

// Serialized into the widget extension's JS bundle: self-contained. Props are
// native's RevivalActivityState verbatim; `revivesAt` is seconds since 2001
// (Swift's default Date encoding).
export function InfinitusRevival(
  props: InfinitusRevivalActivityState,
  environment: LiveActivityEnvironment,
): LiveActivityLayout {
  "widget";

  const primary = "primary";
  const secondary = "secondary";
  const isLight = environment.colorScheme === "light";
  const accent = environment.isLuminanceReduced
    ? secondary
    : props.revived
      ? isLight
        ? "#059669"
        : "#6ee7b7"
      : isLight
        ? "#dc2626"
        : "#fca5a5";
  const revivesAt = new Date((props.revivesAt + 978307200) * 1000);
  const clock = revivesAt.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const headline = props.revived
    ? `${props.reviver} ${props.reviveWord}`
    : `Every account ${props.deadWord}`;
  const detail = props.revived
    ? "The fleet is back."
    : `${props.reviver} ${props.reviveWord} at ${clock}`;
  const sessions =
    props.sessions === 0
      ? "no sessions"
      : `${props.sessions} session${props.sessions === 1 ? "" : "s"}${props.waiting > 0 ? ` · ${props.waiting} waiting` : ""}`;
  const later = props.later.length > 0 ? `then ${props.later.join(", ")}` : null;
  const glyph = props.revived ? "checkmark.circle.fill" : "moon.zzz.fill";

  return {
    banner: (
      <VStack alignment="leading" spacing={6} modifiers={[padding({ all: 14 })]}>
        <HStack spacing={6} alignment="center">
          <Image
            systemName={glyph}
            modifiers={[frame({ width: 13, height: 13 }), foregroundStyle(accent)]}
          />
          <Text
            modifiers={[
              font({ weight: "semibold", size: 13 }),
              foregroundStyle(accent),
              lineLimit(1),
            ]}
          >
            {headline}
          </Text>
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
        <Text modifiers={[font({ size: 13 }), foregroundStyle(primary), lineLimit(1)]}>
          {detail}
        </Text>
        {later ? (
          <Text modifiers={[font({ size: 11 }), foregroundStyle(secondary), lineLimit(1)]}>
            {later}
          </Text>
        ) : null}
      </VStack>
    ),
    bannerSmall: (
      <VStack alignment="leading" spacing={5} modifiers={[padding({ all: 10 })]}>
        <HStack spacing={6} alignment="center">
          <Image
            systemName={glyph}
            modifiers={[frame({ width: 13, height: 13 }), foregroundStyle(accent)]}
          />
          <Text
            modifiers={[font({ weight: "bold", size: 13 }), foregroundStyle(accent), lineLimit(1)]}
          >
            {headline}
          </Text>
        </HStack>
        <Text modifiers={[font({ size: 12 }), foregroundStyle(primary), lineLimit(2)]}>
          {detail}
        </Text>
      </VStack>
    ),
    compactLeading: (
      <Image
        systemName={glyph}
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
        {props.revived ? "back" : clock}
      </Text>
    ),
    minimal: (
      <Image
        systemName={glyph}
        modifiers={[frame({ width: 12, height: 12 }), foregroundStyle(accent)]}
      />
    ),
    expandedLeading: (
      <HStack spacing={5} alignment="center" modifiers={[padding({ leading: 4, vertical: 4 })]}>
        <Image
          systemName={glyph}
          modifiers={[frame({ width: 13, height: 13 }), foregroundStyle(accent)]}
        />
        <Text
          modifiers={[font({ weight: "bold", size: 13 }), foregroundStyle(accent), lineLimit(1)]}
        >
          {props.reviver}
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
        {props.revived ? "revived" : clock}
      </Text>
    ),
    expandedBottom: (
      <VStack alignment="leading" spacing={4} modifiers={[padding({ vertical: 2, horizontal: 8 })]}>
        <Text modifiers={[font({ size: 12 }), foregroundStyle(primary), lineLimit(1)]}>
          {detail}
        </Text>
        <Text modifiers={[font({ size: 11 }), foregroundStyle(secondary), lineLimit(1)]}>
          {later ?? sessions}
        </Text>
      </VStack>
    ),
  };
}

export default createLiveActivity<InfinitusRevivalActivityState>(
  INFINITUS_REVIVAL_ACTIVITY_NAME,
  InfinitusRevival,
);
