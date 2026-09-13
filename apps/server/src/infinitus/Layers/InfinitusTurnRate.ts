import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { ProjectionTurnUsageRepository } from "../../persistence/ProjectionTurnUsage.ts";
import { InfinitusTurnRate } from "../Services/InfinitusTurnRate.ts";

/** The rolling window the Utilization page's live line reads. Five minutes is
    the window the Mac's retired transcript-tail rate used, so the sentence
    keeps its meaning. */
export const TURN_RATE_WINDOW_MINUTES = 5;

/**
 * Fork (#1127): the live token rate of the threads this server runs. A turn's
 * usage row is written when the turn completes, so the window sums the turns
 * that finished inside it — no sampling, no extra bookkeeping, and nothing to
 * lose across a restart.
 */
export const InfinitusTurnRateLive = Layer.effect(
  InfinitusTurnRate,
  Effect.gen(function* () {
    const turnUsage = yield* ProjectionTurnUsageRepository;
    const empty = {
      windowMinutes: TURN_RATE_WINDOW_MINUTES,
      turns: 0,
      inputTokens: 0,
      outputTokens: 0,
    };
    return InfinitusTurnRate.of({
      read: Effect.gen(function* () {
        const now = yield* DateTime.now;
        const since = DateTime.formatIso(
          DateTime.subtract(now, { minutes: TURN_RATE_WINDOW_MINUTES }),
        );
        const sum = yield* turnUsage.sumSince({ since });
        return { ...empty, ...sum };
      }).pipe(
        Effect.catchCause((cause) =>
          Effect.logWarning("infinitus.turnRate.read-failed", cause).pipe(Effect.as(empty)),
        ),
      ),
    });
  }),
);
