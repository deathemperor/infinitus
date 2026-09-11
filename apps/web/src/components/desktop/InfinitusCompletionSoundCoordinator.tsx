import { useEffect, useRef } from "react";

import {
  playCompletionSound,
  useCompletionSoundPreference,
} from "../../lib/infinitusCompletionSound";
import {
  type SeenTurn,
  turnsJustCompleted,
  windowInBackground,
} from "../../lib/infinitusCompletionSound.logic";
import { useThreadShells } from "../../state/entities";

/**
 * Rings the completion sound (#270 H) when any thread's turn finishes while
 * this window is in the background. Mounted once from `__root.tsx`; nothing
 * rendered. One ring per render however many turns finished in it.
 */
export function InfinitusCompletionSoundCoordinator() {
  const shells = useThreadShells();
  const preference = useCompletionSoundPreference();
  const seen = useRef<ReadonlyMap<string, SeenTurn | null>>(new Map());

  useEffect(() => {
    const { completed, next } = turnsJustCompleted(seen.current, shells);
    seen.current = next;
    if (completed.length === 0 || !preference.enabled) return;
    if (windowInBackground(document)) playCompletionSound(preference.sound);
  }, [shells, preference]);

  return null;
}
