import { pinOrderKeyBetween } from "@t3tools/client-runtime/state/thread-sort";

/** What a server lets a client do with pins, from its capability flags. */
export interface PinningSupport {
  readonly pin: boolean;
  readonly reorder: boolean;
}

export function pinningSupport(
  capabilities:
    | { readonly threadPinning?: boolean; readonly threadPinReorder?: boolean }
    | undefined,
): PinningSupport {
  return {
    pin: capabilities?.threadPinning === true,
    reorder: capabilities?.threadPinReorder === true,
  };
}

/** Same placement as the web and the thread list: a fresh pin takes the top
    of the arranged run. Undefined when no pinned thread carries a key yet
    (the server then falls back to creation order). */
export function newPinOrderKey(
  shells: Iterable<{
    readonly pinnedAt?: string | null | undefined;
    readonly pinOrderKey?: string | null | undefined;
  }>,
): string | undefined {
  let firstKey: string | null = null;
  for (const shell of shells) {
    if (shell.pinnedAt == null || shell.pinOrderKey == null) continue;
    if (firstKey === null || shell.pinOrderKey < firstKey) firstKey = shell.pinOrderKey;
  }
  return pinOrderKeyBetween(null, firstKey) ?? undefined;
}
