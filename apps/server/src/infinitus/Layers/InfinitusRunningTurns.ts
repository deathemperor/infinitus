import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";

/** #829: every provider session with an active turn. The status is not
    consulted: a turn waiting on an approval or an input request is as
    live as one streaming, and both die with the process. */
export const InfinitusRunningTurnsLive = Layer.effect(
  InfinitusRunningTurns,
  Effect.gen(function* () {
    const providers = yield* ProviderService;
    return InfinitusRunningTurns.of({
      list: providers
        .listSessions()
        .pipe(
          Effect.map((sessions) =>
            sessions.flatMap((session) =>
              session.activeTurnId !== undefined
                ? [{ threadId: session.threadId, turnId: session.activeTurnId }]
                : [],
            ),
          ),
        ),
    });
  }),
);
