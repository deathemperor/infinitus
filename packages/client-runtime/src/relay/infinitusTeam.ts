import { RelayApi } from "@infinitus/contracts/relay";
import type {
  TeamCommandCreate,
  TeamCommandState,
  TeamDocumentRow,
  TeamDocumentsQuery,
  TeamGrant,
  TeamGrantCreate,
  TeamInviteCreated,
  TeamJoinResponse,
  TeamListRow,
  TeamMeUpdate,
  TeamPendingCommand,
  TeamPolicyRequests,
  TeamSnapshot,
  TeamTranscriptChunkRow,
} from "@infinitus/contracts/relayInfinitusTeam";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Predicate from "effect/Predicate";
import * as FetchHttpClient from "effect/unstable/http/FetchHttpClient";
import * as HttpApiClient from "effect/unstable/httpapi/HttpApiClient";

import { findErrorTraceId } from "../errors/errorTrace.ts";

/**
 * The relay's `infinitusTeam` group for the web and the phone (#1592): one
 * client over `RelayApi` with the user's Clerk token read per call, so a
 * signed-out user gets `signedOut` rather than a 401, and the relay's
 * refusal sentence travels verbatim as `refused`. Promises, since both
 * panes are React and neither runs an Effect runtime of its own.
 */
export type InfinitusTeamErrorKind = "signedOut" | "refused" | "failed";

export class InfinitusTeamError extends Error {
  override readonly name = "InfinitusTeamError";
  readonly kind: InfinitusTeamErrorKind;
  readonly traceId: string | null;
  constructor(kind: InfinitusTeamErrorKind, message: string, traceId: string | null = null) {
    super(message);
    this.kind = kind;
    this.traceId = traceId;
  }
}

export interface InfinitusTeamClientOptions {
  readonly relayUrl: string;
  /** Null when signed out. */
  readonly readClerkToken: () => Promise<string | null>;
}

export interface InfinitusTeamClient {
  readonly listTeams: () => Promise<ReadonlyArray<TeamListRow>>;
  readonly createTeam: (input: { name: string; memberName: string }) => Promise<TeamSnapshot>;
  readonly joinTeam: (input: { token: string; memberName: string }) => Promise<TeamJoinResponse>;
  readonly getTeam: (teamId: string) => Promise<TeamSnapshot>;
  readonly updateMe: (teamId: string, update: TeamMeUpdate) => Promise<TeamSnapshot>;
  readonly leaveTeam: (teamId: string) => Promise<void>;
  readonly createInvite: (
    teamId: string,
    input: { days: number; oneUse: boolean },
  ) => Promise<TeamInviteCreated>;
  readonly revokeInvite: (teamId: string, inviteId: string) => Promise<void>;
  readonly approveRequest: (teamId: string, userId: string) => Promise<TeamSnapshot>;
  readonly declineRequest: (teamId: string, userId: string) => Promise<TeamSnapshot>;
  readonly promoteMember: (teamId: string, userId: string) => Promise<TeamSnapshot>;
  readonly demoteMember: (teamId: string, userId: string) => Promise<TeamSnapshot>;
  readonly removeMember: (teamId: string, userId: string) => Promise<TeamSnapshot>;
  readonly updatePolicy: (teamId: string, requests: TeamPolicyRequests) => Promise<TeamSnapshot>;
  readonly listDocuments: (
    teamId: string,
    query: TeamDocumentsQuery,
  ) => Promise<ReadonlyArray<TeamDocumentRow>>;
  readonly listTranscriptChunks: (input: {
    teamId: string;
    userId: string;
    environmentId: string;
    threadId: string;
  }) => Promise<ReadonlyArray<TeamTranscriptChunkRow>>;
  readonly readTranscriptChunk: (input: {
    teamId: string;
    userId: string;
    environmentId: string;
    threadId: string;
    seq: number;
  }) => Promise<string>;
  readonly createGrant: (teamId: string, input: TeamGrantCreate) => Promise<TeamGrant>;
  readonly revokeGrant: (teamId: string, grantId: string) => Promise<void>;
  readonly createCommand: (teamId: string, input: TeamCommandCreate) => Promise<TeamCommandState>;
  readonly listPendingCommands: (teamId: string) => Promise<ReadonlyArray<TeamPendingCommand>>;
  readonly getCommand: (teamId: string, commandId: string) => Promise<TeamCommandState>;
  readonly allowCommand: (teamId: string, commandId: string) => Promise<TeamCommandState>;
  readonly denyCommand: (teamId: string, commandId: string) => Promise<TeamCommandState>;
}

const makeApi = (relayUrl: string) => HttpApiClient.make(RelayApi, { baseUrl: relayUrl });
type Api = Effect.Success<ReturnType<typeof makeApi>>["infinitusTeam"];
/** The bearer header every team route declares. */
interface Bearer {
  readonly headers: { readonly authorization: string };
}

const signedOut = () =>
  new InfinitusTeamError("signedOut", "Sign in to Infinitus Connect to use Team.");

function toTeamError(error: unknown): InfinitusTeamError {
  if (error instanceof InfinitusTeamError) return error;
  const traceId = findErrorTraceId(error);
  if (Predicate.hasProperty(error, "_tag")) {
    if (error._tag === "RelayInfinitusTeamRefusedError" && Predicate.hasProperty(error, "reason")) {
      return new InfinitusTeamError("refused", String(error.reason), traceId);
    }
    if (error._tag === "RelayAuthInvalidError") {
      return new InfinitusTeamError("signedOut", "Sign in to Infinitus Connect again.", traceId);
    }
  }
  const message =
    error instanceof Error && error.message.length > 0
      ? error.message
      : "Infinitus Connect did not answer.";
  return new InfinitusTeamError("failed", message, traceId);
}

export function makeInfinitusTeamClient(options: InfinitusTeamClientOptions): InfinitusTeamClient {
  const call = async <A, E>(run: (api: Api, auth: Bearer) => Effect.Effect<A, E>): Promise<A> => {
    const token = await options.readClerkToken().catch(() => null);
    if (token === null) throw signedOut();
    const auth: Bearer = { headers: { authorization: `Bearer ${token}` } };
    const exit = await Effect.runPromiseExit(
      makeApi(options.relayUrl).pipe(
        Effect.flatMap((api) => run(api.infinitusTeam, auth)),
        Effect.provide(FetchHttpClient.layer),
      ),
    );
    if (Exit.isSuccess(exit)) return exit.value;
    throw toTeamError(Cause.squash(exit.cause));
  };
  const team = (teamId: string) => ({ teamId: teamId as TeamSnapshot["teamId"] });
  const member = (teamId: string, userId: string) => ({ ...team(teamId), userId });
  return {
    listTeams: () => call((api, auth) => api.listTeams({ ...auth })),
    createTeam: (payload) => call((api, auth) => api.createTeam({ ...auth, payload })),
    joinTeam: (payload) => call((api, auth) => api.joinTeam({ ...auth, payload })),
    getTeam: (teamId) => call((api, auth) => api.getTeam({ ...auth, params: team(teamId) })),
    updateMe: (teamId, payload) =>
      call((api, auth) => api.updateMe({ ...auth, params: team(teamId), payload })),
    leaveTeam: (teamId) =>
      call((api, auth) => api.leaveTeam({ ...auth, params: team(teamId) })).then(() => {}),
    createInvite: (teamId, payload) =>
      call((api, auth) => api.createInvite({ ...auth, params: team(teamId), payload })),
    revokeInvite: (teamId, inviteId) =>
      call((api, auth) =>
        api.revokeInvite({ ...auth, params: { ...team(teamId), inviteId } }),
      ).then(() => {}),
    approveRequest: (teamId, userId) =>
      call((api, auth) => api.approveRequest({ ...auth, params: member(teamId, userId) })),
    declineRequest: (teamId, userId) =>
      call((api, auth) => api.declineRequest({ ...auth, params: member(teamId, userId) })),
    promoteMember: (teamId, userId) =>
      call((api, auth) => api.promoteMember({ ...auth, params: member(teamId, userId) })),
    demoteMember: (teamId, userId) =>
      call((api, auth) => api.demoteMember({ ...auth, params: member(teamId, userId) })),
    removeMember: (teamId, userId) =>
      call((api, auth) => api.removeMember({ ...auth, params: member(teamId, userId) })),
    updatePolicy: (teamId, requests) =>
      call((api, auth) =>
        api.updatePolicy({ ...auth, params: team(teamId), payload: { requests } }),
      ),
    listDocuments: (teamId, query) =>
      call((api, auth) => api.listDocuments({ ...auth, params: team(teamId), query })),
    listTranscriptChunks: (input) =>
      call((api, auth) =>
        api.listTranscriptChunks({
          ...auth,
          params: {
            ...team(input.teamId),
            userId: input.userId,
            environmentId: input.environmentId as TeamGrant["environmentId"],
            threadId: input.threadId,
          },
        }),
      ),
    readTranscriptChunk: (input) =>
      call((api, auth) =>
        api.readTranscriptChunk({
          ...auth,
          params: {
            ...team(input.teamId),
            userId: input.userId,
            environmentId: input.environmentId as TeamGrant["environmentId"],
            threadId: input.threadId,
            seq: input.seq,
          },
        }),
      ).then((chunk) => chunk.lines),
    createGrant: (teamId, payload) =>
      call((api, auth) => api.createGrant({ ...auth, params: team(teamId), payload })),
    revokeGrant: (teamId, grantId) =>
      call((api, auth) => api.revokeGrant({ ...auth, params: { ...team(teamId), grantId } })).then(
        () => {},
      ),
    createCommand: (teamId, payload) =>
      call((api, auth) => api.createCommand({ ...auth, params: team(teamId), payload })),
    listPendingCommands: (teamId) =>
      call((api, auth) => api.listPendingCommands({ ...auth, params: team(teamId) })),
    getCommand: (teamId, commandId) =>
      call((api, auth) => api.getCommand({ ...auth, params: { ...team(teamId), commandId } })),
    allowCommand: (teamId, commandId) =>
      call((api, auth) => api.allowCommand({ ...auth, params: { ...team(teamId), commandId } })),
    denyCommand: (teamId, commandId) =>
      call((api, auth) => api.denyCommand({ ...auth, params: { ...team(teamId), commandId } })),
  };
}
