import { useAtomValue } from "@effect/atom-react";

import { environmentServerConfigsAtom } from "~/state/server";

/**
 * Whether any connected server drives an Infinitus app. One is enough: the
 * pages that need the app pick their environment themselves, the way the
 * pull requests page does; the callers only decide whether an entry point
 * (a sidebar item, a settings section) leads anywhere at all.
 *
 * Reads through a selector so a caller wakes only when the answer flips;
 * `CommandPalette` wraps the whole app.
 */
export function useInfinitusSupported(): boolean {
  return useAtomValue(environmentServerConfigsAtom, (configs) =>
    [...configs.values()].some((config) => config.environment.capabilities.infinitus === true),
  );
}
