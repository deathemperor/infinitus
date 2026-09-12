import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { ProviderService } from "../../provider/Services/ProviderService.ts";
import { InfinitusRunningTurns } from "../Services/InfinitusRunningTurns.ts";

/** #829: a live provider session in `running` with an active turn. */
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
              session.status === "running" && session.activeTurnId !== undefined
                ? [{ threadId: session.threadId, turnId: session.activeTurnId }]
                : [],
            ),
          ),
        ),
    });
  }),
);
