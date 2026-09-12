import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import { TurnStartGate } from "../../orchestration/Services/TurnStartGate.ts";
import { ProviderSessionDirectory } from "../../provider/Services/ProviderSessionDirectory.ts";
import { latestClaudeForkAnchor } from "../ThreadFork.ts";

/**
 * Fork (#269 C, #1013): a fork bound at the source's latest turn may fall
 * back to the source session's end when its anchor is missing from the
 * transcript (`resumeSessionAtLatest`, see `claudeForkFallback.logic.ts`).
 * That verdict was taken when the fork was bound; if the source completed
 * more turns before the fork's first start, the session's end is no longer
 * that turn and the fallback would land past it silently. So every turn
 * start re-checks: a fork cursor still carrying the flag whose source
 * session's latest anchor is no longer the fork point loses the flag, and
 * a missing anchor then fails plainly. Wraps the gate the reactor calls.
 */

interface PendingLatestFork {
  readonly resume: string;
  readonly resumeSessionAt: string;
  readonly resumeSessionAtLatest: true;
  readonly fork: true;
}

function pendingLatestFork(resumeCursor: unknown): PendingLatestFork | null {
  if (!resumeCursor || typeof resumeCursor !== "object") return null;
  const cursor = resumeCursor as Partial<PendingLatestFork>;
  return cursor.fork === true &&
    cursor.resumeSessionAtLatest === true &&
    typeof cursor.resume === "string" &&
    typeof cursor.resumeSessionAt === "string"
    ? (cursor as PendingLatestFork)
    : null;
}

/** The fork cursor without its fallback flag once the source moved past the fork point; null when it may stay. */
export function forkCursorAfterRecheck(
  forkCursor: unknown,
  sourceCursors: ReadonlyArray<unknown>,
): Record<string, unknown> | null {
  const pending = pendingLatestFork(forkCursor);
  if (pending === null) return null;
  for (const sourceCursor of sourceCursors) {
    const latest = latestClaudeForkAnchor(sourceCursor);
    if (latest === null || latest.sessionId !== pending.resume) continue;
    if (latest.at === pending.resumeSessionAt) return null;
    const { resumeSessionAtLatest: _latest, ...rest } = forkCursor as Record<string, unknown>;
    return rest;
  }
  return null;
}

export const InfinitusForkAnchorGate = Layer.effect(
  TurnStartGate,
  Effect.gen(function* () {
    const inner = yield* TurnStartGate;
    const directory = yield* ProviderSessionDirectory;
    const recheck = (threadId: Parameters<typeof directory.getBinding>[0]) =>
      Effect.gen(function* () {
        const binding = yield* directory.getBinding(threadId);
        if (Option.isNone(binding) || pendingLatestFork(binding.value.resumeCursor) === null)
          return;
        const bindings = yield* directory.listBindings();
        const next = forkCursorAfterRecheck(
          binding.value.resumeCursor,
          bindings.map((candidate) => candidate.resumeCursor),
        );
        if (next === null) return;
        yield* Effect.logInfo("infinitus.fork.anchor-stale", { threadId });
        yield* directory.upsert({ ...binding.value, resumeCursor: next });
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.fork.anchor-recheck-failed", { threadId, cause }),
        ),
      );
    return TurnStartGate.of({
      start: (input) => recheck(input.threadId).pipe(Effect.flatMap(() => inner.start(input))),
    });
  }),
);
