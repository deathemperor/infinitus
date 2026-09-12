import {
  AuthOrchestrationOperateScope,
  AuthOrchestrationReadScope,
  EnvironmentHttpApi,
} from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Stream from "effect/Stream";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import { annotateEnvironmentRequest, requireEnvironmentScope } from "../../auth/http.ts";
import { InfinitusLimitStops } from "../Services/InfinitusLimitStops.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";
import { InfinitusSessionHold } from "../Services/InfinitusSessionHold.ts";
import { InfinitusSessionInterrupt } from "../Services/InfinitusSessionInterrupt.ts";

/** The list a whole-list stream shows on subscribe. Contract: `held` and
    `stopped` emit their current list to every subscriber at once (#741,
    #270 I); a stream that only emitted on change would hang this read. */
const current = <A>(stream: Stream.Stream<ReadonlyArray<A>>) =>
  Stream.runHead(stream).pipe(Effect.map(Option.getOrElse((): ReadonlyArray<A> => [])));

/**
 * Fork (#822): `infinitusctl`'s two reads over plain HTTP. `holds` is the WS
 * holds stream's list (held for headroom, stopped on a limit) plus the turns
 * paused for headroom (#743); `releaseThread` is the WS `infinitus.releaseThread`
 * word for word — a held start runs, else a paused turn continues, else the
 * reason. Both take the operate scope, as their WS twins do.
 */
export const infinitusHttpApiLayer = HttpApiBuilder.group(
  EnvironmentHttpApi,
  "infinitus",
  Effect.fnUntraced(function* (handlers) {
    const hold = yield* InfinitusSessionHold;
    const stops = yield* InfinitusLimitStops;
    const interrupt = yield* InfinitusSessionInterrupt;
    const runningTurns = yield* InfinitusRunningTurns;
    return handlers
      .handle(
        "runningTurns",
        Effect.fn("environment.infinitus.runningTurns")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          yield* requireEnvironmentScope(AuthOrchestrationReadScope);
          return yield* runningTurns.list;
        }),
      )
      .handle(
        "holds",
        Effect.fn("environment.infinitus.holds")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          yield* requireEnvironmentScope(AuthOrchestrationOperateScope);
          const [held, stopped, paused] = yield* Effect.all([
            current(hold.held),
            current(stops.stopped),
            interrupt.paused,
          ]);
          return [...held, ...stopped, ...paused];
        }),
      )
      .handle(
        "releaseThread",
        Effect.fn("environment.infinitus.releaseThread")(function* (args) {
          yield* annotateEnvironmentRequest(args.endpoint.name);
          yield* requireEnvironmentScope(AuthOrchestrationOperateScope);
          const held = yield* hold.release(args.payload.threadId);
          if (held.released) return held;
          const paused = yield* interrupt.resume(args.payload.threadId);
          return paused.released
            ? paused
            : { released: false, reason: "nothing is held or paused" };
        }),
      );
  }),
);
