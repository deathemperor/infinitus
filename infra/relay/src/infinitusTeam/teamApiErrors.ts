import { RelayInternalError } from "@infinitus/contracts/relay";
import { RelayInfinitusTeamRefusedError } from "@infinitus/contracts/relayInfinitusTeam";
import * as Effect from "effect/Effect";

import type { TeamServiceError } from "./InfinitusTeamService.ts";

const currentTraceId = Effect.currentParentSpan.pipe(
  Effect.map((span) => span.traceId),
  Effect.orElseSucceed(() => "unavailable"),
);

const toApiError = (error: TeamServiceError, traceId: string) =>
  error._tag === "TeamRefused"
    ? new RelayInfinitusTeamRefusedError({
        code: "infinitus_team_refused",
        reason: error.reason,
        traceId,
      })
    : new RelayInternalError({ code: "internal_error", reason: "persistence_failed", traceId });

/** The one mapping both team groups share: a `TeamRefused` is the caller's
    (409, its sentence verbatim); every store or link failure is the relay's
    (500, `persistence_failed`). */
export const mapTeamErrors = <A, R>(
  effect: Effect.Effect<A, TeamServiceError, R>,
): Effect.Effect<A, RelayInfinitusTeamRefusedError | RelayInternalError, R> =>
  Effect.gen(function* () {
    const traceId = yield* currentTraceId;
    return yield* effect.pipe(Effect.mapError((error) => toApiError(error, traceId)));
  });
