import {
  RelayApi,
  RelayAuthInvalidError,
  RelayEnvironmentPrincipal,
} from "@infinitus/contracts/relay";
import { TEAM_USER_HEADER } from "@infinitus/contracts/relayInfinitusTeam";
import * as Effect from "effect/Effect";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import { InfinitusTeamService } from "./InfinitusTeamService.ts";
import { mapTeamErrors } from "./teamApiErrors.ts";

const currentTraceId = Effect.currentParentSpan.pipe(
  Effect.map((span) => span.traceId),
  Effect.orElseSucceed(() => "unavailable"),
);

/**
 * The `infinitusTeamEnvironment` group (#1592): what the desktop server
 * publishes and runs with its environment credential. The principal is the
 * environment; the user it acts for comes in the payload or the
 * `x-infinitus-user` header, and the service refuses unless that user's link
 * to this environment and key is live.
 */
export const infinitusTeamEnvironmentApi = HttpApiBuilder.group(
  RelayApi,
  "infinitusTeamEnvironment",
  Effect.fnUntraced(function* (handlers) {
    const service = yield* InfinitusTeamService;
    const principalFor = (environmentId: string) =>
      RelayEnvironmentPrincipal.pipe(
        Effect.flatMap((principal) =>
          principal.environmentId === environmentId
            ? Effect.succeed(principal)
            : currentTraceId.pipe(
                Effect.flatMap((traceId) =>
                  Effect.fail(
                    new RelayAuthInvalidError({
                      code: "auth_invalid",
                      reason: "not_authorized",
                      traceId,
                    }),
                  ),
                ),
              ),
        ),
      );
    return handlers
      .handle(
        "memberships",
        Effect.fn("relay.api.infinitus_team_env.memberships")(function* ({ params, headers }) {
          const principal = yield* principalFor(params.environmentId);
          return yield* service
            .memberships({
              userId: headers[TEAM_USER_HEADER],
              environmentId: principal.environmentId,
              environmentPublicKey: principal.environmentPublicKey,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "publishDocuments",
        Effect.fn("relay.api.infinitus_team_env.publish_documents")(function* ({
          params,
          payload,
        }) {
          const principal = yield* principalFor(params.environmentId);
          yield* service
            .publishDocuments({
              userId: payload.userId,
              environmentId: principal.environmentId,
              environmentPublicKey: principal.environmentPublicKey,
              teamId: params.teamId,
              documents: payload.documents,
            })
            .pipe(mapTeamErrors);
          return { ok: true as const };
        }),
      )
      .handle(
        "publishTranscript",
        Effect.fn("relay.api.infinitus_team_env.publish_transcript")(function* ({
          params,
          payload,
        }) {
          const principal = yield* principalFor(params.environmentId);
          yield* service
            .publishTranscript({
              userId: payload.userId,
              environmentId: principal.environmentId,
              environmentPublicKey: principal.environmentPublicKey,
              teamId: params.teamId,
              threadId: payload.threadId,
              seq: payload.seq,
              rows: payload.rows,
              lines: payload.lines,
            })
            .pipe(mapTeamErrors);
          return { ok: true as const };
        }),
      )
      .handle(
        "pollCommands",
        Effect.fn("relay.api.infinitus_team_env.poll_commands")(function* ({ params, headers }) {
          const principal = yield* principalFor(params.environmentId);
          return yield* service
            .pollCommands({
              userId: headers[TEAM_USER_HEADER],
              environmentId: principal.environmentId,
              environmentPublicKey: principal.environmentPublicKey,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "ackCommand",
        Effect.fn("relay.api.infinitus_team_env.ack_command")(function* ({ params, payload }) {
          const principal = yield* principalFor(params.environmentId);
          yield* service
            .ackCommand({
              userId: payload.userId,
              environmentId: principal.environmentId,
              environmentPublicKey: principal.environmentPublicKey,
              commandId: params.commandId,
              outcome: payload.outcome,
              ...(payload.detail === undefined ? {} : { detail: payload.detail }),
              ...(payload.result === undefined ? {} : { result: payload.result }),
            })
            .pipe(mapTeamErrors);
          return { ok: true as const };
        }),
      );
  }),
);
