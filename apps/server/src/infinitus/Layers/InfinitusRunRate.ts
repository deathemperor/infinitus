import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";

import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusRunRate } from "../Services/InfinitusRunRate.ts";
import {
  foldRunRate,
  runRateSample,
  withinWindow,
  type RunRateSample,
} from "./infinitusRunRate.logic.ts";

/**
 * Fork (#1127): a live tokens-per-minute from the turns this server runs,
 * the thread-side replacement for the Mac's transcript-tail rate, which
 * retired with the terminal session tracker.
 *
 * The orchestration already records what every turn cost, so this watches
 * `thread.turn-usage-recorded` and keeps the window's samples — no second
 * count, no read of the projection on every poll. In memory on purpose: a
 * live rate is about the last few minutes, so a restart starting the window
 * over loses nothing worth a migration, and the window prunes itself on
 * every record and every read (a server that stops finishing turns keeps no
 * samples at all).
 */
export const InfinitusRunRateLive = Layer.effect(
  InfinitusRunRate,
  Effect.gen(function* () {
    const orchestrationEngine = yield* OrchestrationEngineService;
    let samples: ReadonlyArray<RunRateSample> = [];

    yield* forkParked(
      orchestrationEngine.streamDomainEvents.pipe(
        Stream.runForEach((event) =>
          Effect.gen(function* () {
            if (event.type !== "thread.turn-usage-recorded") return;
            const sample = runRateSample(event.payload.turnUsage);
            if (sample === null) return;
            const now = DateTime.toEpochMillis(yield* DateTime.now);
            samples = [...withinWindow(samples, now), sample];
          }),
        ),
      ),
    );

    return InfinitusRunRate.of({
      read: Effect.gen(function* () {
        const now = DateTime.toEpochMillis(yield* DateTime.now);
        samples = withinWindow(samples, now);
        return foldRunRate(samples, now);
      }),
    });
  }),
);
