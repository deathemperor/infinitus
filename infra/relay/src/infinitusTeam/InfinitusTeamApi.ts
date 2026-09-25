import { RelayApi, RelayClientPrincipal } from "@infinitus/contracts/relay";
import * as Effect from "effect/Effect";
import * as HttpApiBuilder from "effect/unstable/httpapi/HttpApiBuilder";

import { InfinitusTeamService } from "./InfinitusTeamService.ts";
import { mapTeamErrors } from "./teamApiErrors.ts";

/**
 * The `infinitusTeam` group (#1592): every route the web and the phone call
 * with the user's Clerk token. Each handler is one service call for the
 * principal's user; the rules live in `InfinitusTeamService`.
 */
export const infinitusTeamApi = HttpApiBuilder.group(
  RelayApi,
  "infinitusTeam",
  Effect.fnUntraced(function* (handlers) {
    const service = yield* InfinitusTeamService;
    const user = RelayClientPrincipal.pipe(Effect.map((principal) => principal.userId));
    return handlers
      .handle(
        "listTeams",
        Effect.fn("relay.api.infinitus_team.list")(function* () {
          return yield* service.listTeams(yield* user).pipe(mapTeamErrors);
        }),
      )
      .handle(
        "createTeam",
        Effect.fn("relay.api.infinitus_team.create")(function* ({ payload }) {
          return yield* service
            .createTeam({ userId: yield* user, name: payload.name, memberName: payload.memberName })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "joinTeam",
        Effect.fn("relay.api.infinitus_team.join")(function* ({ payload }) {
          return yield* service
            .joinTeam({ userId: yield* user, token: payload.token, memberName: payload.memberName })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "getTeam",
        Effect.fn("relay.api.infinitus_team.get")(function* ({ params }) {
          return yield* service
            .getTeam({ userId: yield* user, teamId: params.teamId })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "updateMe",
        Effect.fn("relay.api.infinitus_team.update_me")(function* ({ params, payload }) {
          return yield* service
            .updateMe({
              userId: yield* user,
              teamId: params.teamId,
              ...(payload.name === undefined ? {} : { name: payload.name }),
              ...(payload.shares === undefined ? {} : { shares: payload.shares }),
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "leaveTeam",
        Effect.fn("relay.api.infinitus_team.leave")(function* ({ params }) {
          yield* service
            .leaveTeam({ userId: yield* user, teamId: params.teamId })
            .pipe(mapTeamErrors);
          return { ok: true as const };
        }),
      )
      .handle(
        "createInvite",
        Effect.fn("relay.api.infinitus_team.create_invite")(function* ({ params, payload }) {
          return yield* service
            .createInvite({
              userId: yield* user,
              teamId: params.teamId,
              days: payload.days,
              oneUse: payload.oneUse,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "revokeInvite",
        Effect.fn("relay.api.infinitus_team.revoke_invite")(function* ({ params }) {
          yield* service
            .revokeInvite({ userId: yield* user, teamId: params.teamId, inviteId: params.inviteId })
            .pipe(mapTeamErrors);
          return { ok: true as const };
        }),
      )
      .handle(
        "approveRequest",
        Effect.fn("relay.api.infinitus_team.approve")(function* ({ params }) {
          return yield* service
            .approveRequest({
              userId: yield* user,
              teamId: params.teamId,
              targetUserId: params.userId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "declineRequest",
        Effect.fn("relay.api.infinitus_team.decline")(function* ({ params }) {
          return yield* service
            .declineRequest({
              userId: yield* user,
              teamId: params.teamId,
              targetUserId: params.userId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "promoteMember",
        Effect.fn("relay.api.infinitus_team.promote")(function* ({ params }) {
          return yield* service
            .promoteMember({
              userId: yield* user,
              teamId: params.teamId,
              targetUserId: params.userId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "demoteMember",
        Effect.fn("relay.api.infinitus_team.demote")(function* ({ params }) {
          return yield* service
            .demoteMember({
              userId: yield* user,
              teamId: params.teamId,
              targetUserId: params.userId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "removeMember",
        Effect.fn("relay.api.infinitus_team.remove")(function* ({ params }) {
          return yield* service
            .removeMember({
              userId: yield* user,
              teamId: params.teamId,
              targetUserId: params.userId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "updatePolicy",
        Effect.fn("relay.api.infinitus_team.update_policy")(function* ({ params, payload }) {
          return yield* service
            .updatePolicy({
              userId: yield* user,
              teamId: params.teamId,
              requests: payload.requests,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "listDocuments",
        Effect.fn("relay.api.infinitus_team.list_documents")(function* ({ params, query }) {
          return yield* service
            .listDocuments({
              userId: yield* user,
              teamId: params.teamId,
              ...(query.userId === undefined ? {} : { ownerUserId: query.userId }),
              ...(query.environmentId === undefined ? {} : { environmentId: query.environmentId }),
              ...(query.kind === undefined ? {} : { kind: query.kind }),
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "listTranscriptChunks",
        Effect.fn("relay.api.infinitus_team.list_transcript_chunks")(function* ({ params }) {
          return yield* service
            .listTranscriptChunks({
              userId: yield* user,
              teamId: params.teamId,
              ownerUserId: params.userId,
              environmentId: params.environmentId,
              threadId: params.threadId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "readTranscriptChunk",
        Effect.fn("relay.api.infinitus_team.read_transcript_chunk")(function* ({ params }) {
          const lines = yield* service
            .readTranscriptChunk({
              userId: yield* user,
              teamId: params.teamId,
              ownerUserId: params.userId,
              environmentId: params.environmentId,
              threadId: params.threadId,
              seq: params.seq,
            })
            .pipe(mapTeamErrors);
          return { lines };
        }),
      )
      .handle(
        "createGrant",
        Effect.fn("relay.api.infinitus_team.create_grant")(function* ({ params, payload }) {
          return yield* service
            .createGrant({ userId: yield* user, teamId: params.teamId, ...payload })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "revokeGrant",
        Effect.fn("relay.api.infinitus_team.revoke_grant")(function* ({ params }) {
          yield* service
            .revokeGrant({ userId: yield* user, teamId: params.teamId, grantId: params.grantId })
            .pipe(mapTeamErrors);
          return { ok: true as const };
        }),
      )
      .handle(
        "createCommand",
        Effect.fn("relay.api.infinitus_team.create_command")(function* ({ params, payload }) {
          return yield* service
            .createCommand({
              userId: yield* user,
              teamId: params.teamId,
              toUserId: payload.toUserId,
              environmentId: payload.environmentId,
              threadId: payload.threadId,
              action: payload.action,
              ...(payload.text === undefined ? {} : { text: payload.text }),
              ...(payload.project === undefined ? {} : { project: payload.project }),
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "listPendingCommands",
        Effect.fn("relay.api.infinitus_team.list_pending")(function* ({ params }) {
          return yield* service
            .listPendingCommands({ userId: yield* user, teamId: params.teamId })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "getCommand",
        Effect.fn("relay.api.infinitus_team.get_command")(function* ({ params }) {
          return yield* service
            .getCommand({ userId: yield* user, teamId: params.teamId, commandId: params.commandId })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "allowCommand",
        Effect.fn("relay.api.infinitus_team.allow_command")(function* ({ params }) {
          return yield* service
            .allowCommand({
              userId: yield* user,
              teamId: params.teamId,
              commandId: params.commandId,
            })
            .pipe(mapTeamErrors);
        }),
      )
      .handle(
        "denyCommand",
        Effect.fn("relay.api.infinitus_team.deny_command")(function* ({ params }) {
          return yield* service
            .denyCommand({
              userId: yield* user,
              teamId: params.teamId,
              commandId: params.commandId,
            })
            .pipe(mapTeamErrors);
        }),
      );
  }),
);
