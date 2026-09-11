import type { OrchestrationLatestTurn, OrchestrationThreadActivity } from "@t3tools/contracts";

/**
 * Session priority mode's held state, read from the thread (#616). The server
 * keeps nothing for it: the hold layer leaves one work-log row when it keeps
 * a start and one when it runs it, so a thread is held while its newest
 * held row has no released row after it and no turn started after it (a
 * restart forgets held starts; the next send starts a turn and ends the
 * stale row's reign). The same kinds as
 * `apps/server/src/infinitus/Layers/infinitusSessionHold.logic.ts`. Interrupt
 * mode (#743) leaves the same pair for a running turn it paused
 * (`infinitusSessionInterrupt.logic.ts`): a paused row opens, a resumed row
 * or a later turn start closes, and `kind` says which the thread is in.
 */
export const HOLD_MARKER_KIND = "infinitus.thread.held";
export const RELEASE_MARKER_KIND = "infinitus.thread.released";
export const PAUSE_MARKER_KIND = "infinitus.thread.paused";
export const RESUME_MARKER_KIND = "infinitus.thread.resumed";
/** Resume-on-limit's pair (#648, #270 I): the stop, and the turn resumed on
    the swapped-to account (`infinitusResumeOnLimit.logic.ts`). */
export const LIMIT_MARKER_KIND = "infinitus.thread.limited";
export const LIMIT_RESUME_MARKER_KIND = "infinitus.turn.resumed";

export interface ThreadHold {
  /** `held`: a start waits for headroom; `paused`: a running turn was
      interrupted for it and waits to continue; `limited`: the turn stopped
      on its account's usage limit and waits for a swap. */
  readonly kind: "held" | "paused" | "limited";
  /** The held row, so a page can remember what it answered for this hold. */
  readonly markerId: string;
  readonly since: string;
  /** The row's own line: "Held for headroom on claude, 5h window 84 %". */
  readonly summary: string;
}

interface Placed {
  readonly activity: OrchestrationThreadActivity;
  readonly index: number;
}

const later = (a: Placed, b: Placed | null): boolean =>
  b === null ||
  a.activity.createdAt > b.activity.createdAt ||
  (a.activity.createdAt === b.activity.createdAt && a.index > b.index);

export function threadHold(thread: {
  readonly activities: ReadonlyArray<OrchestrationThreadActivity>;
  readonly latestTurn: OrchestrationLatestTurn | null;
}): ThreadHold | null {
  let held: Placed | null = null;
  let released: Placed | null = null;
  thread.activities.forEach((activity, index) => {
    const placed = { activity, index };
    const opens =
      activity.kind === HOLD_MARKER_KIND ||
      activity.kind === PAUSE_MARKER_KIND ||
      activity.kind === LIMIT_MARKER_KIND;
    const closes =
      activity.kind === RELEASE_MARKER_KIND ||
      activity.kind === RESUME_MARKER_KIND ||
      activity.kind === LIMIT_RESUME_MARKER_KIND;
    if (opens && later(placed, held)) held = placed;
    else if (closes && later(placed, released)) released = placed;
  });
  if (held === null) return null;
  const hold: Placed = held;
  if (released !== null && later(released, hold)) return null;
  const startedAt = thread.latestTurn?.startedAt ?? null;
  if (startedAt !== null && startedAt >= hold.activity.createdAt) return null;
  return {
    kind:
      hold.activity.kind === PAUSE_MARKER_KIND
        ? "paused"
        : hold.activity.kind === LIMIT_MARKER_KIND
          ? "limited"
          : "held",
    markerId: hold.activity.id,
    since: hold.activity.createdAt,
    summary: hold.activity.summary,
  };
}
