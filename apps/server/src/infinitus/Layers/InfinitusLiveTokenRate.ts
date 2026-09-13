import * as Clock from "effect/Clock";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import { ProjectionTurnUsageRepository } from "../../persistence/ProjectionTurnUsage.ts";
import { InfinitusLiveTokenRate } from "../Services/InfinitusLiveTokenRate.ts";
import { UsageAttribution } from "../Services/UsageAttribution.ts";
import { liveTokenRate, LIVE_RATE_WINDOW_MINUTES } from "./infinitusLiveTokenRate.logic.ts";

/**
 * Fork (#1127): the live output rate off this server's own per-turn usage
 * rows (#834), replacing the Mac's transcript-tail figure, which retires with
 * the terminal sessions (#1041 Lane 4). One indexed range read per call over
 * a five-minute window — no verb, no transcript scan.
 *
 * The per-account split needs #779's swap timeline, which only a server next
 * to Infinitus has; without it the rate is still whole, it simply carries no
 * accounts. A failed read is a null rate and a warning, never an error to the
 * page: a missing number is the same shape as a quiet window.
 */
export const InfinitusLiveTokenRateLive = Layer.effect(
  InfinitusLiveTokenRate,
  Effect.gen(function* () {
    const repository = yield* ProjectionTurnUsageRepository;
    const attribution = yield* Effect.serviceOption(UsageAttribution);
    return InfinitusLiveTokenRate.of({
      read: Effect.gen(function* () {
        const nowMs = yield* Clock.currentTimeMillis;
        const since = DateTime.formatIso(
          DateTime.makeUnsafe(nowMs - LIVE_RATE_WINDOW_MINUTES * 60_000),
        );
        const rows = yield* repository.listCompletedSince({ since });
        const accounts = Option.isSome(attribution) ? yield* attribution.value.resolve : null;
        return liveTokenRate({ rows, nowMs, accounts });
      }).pipe(
        Effect.catchCause((cause) =>
          // The cause only — no thread id, no email.
          Effect.logWarning("Could not read the live token rate", { cause }).pipe(Effect.as(null)),
        ),
        Effect.withSpan("InfinitusLiveTokenRate.read"),
      ),
    });
  }),
);
