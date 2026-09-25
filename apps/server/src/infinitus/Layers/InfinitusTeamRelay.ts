import { CommandId, MessageId, ThreadId, DEFAULT_RUNTIME_MODE } from "@infinitus/contracts";
import type { OrchestrationShellSnapshot } from "@infinitus/contracts";
import { InfinitusTeamDays, type InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { RelayApi } from "@infinitus/contracts/relay";
import {
  TEAM_USER_HEADER,
  type TeamEnvironmentMembership,
  type TeamEnvironmentMemberships,
  type TeamQueuedCommand,
  type TeamShareAudience,
} from "@infinitus/contracts/relayInfinitusTeam";
import { makeRedactor } from "@infinitus/shared/infinitusTeamRedaction";
import * as Cause from "effect/Cause";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schedule from "effect/Schedule";
import * as Schema from "effect/Schema";
import * as HttpApiClient from "effect/unstable/httpapi/HttpApiClient";
import { HttpClient, HttpClientRequest } from "effect/unstable/http";
import * as NodeOS from "node:os";

import * as ServerSecretStore from "../../auth/ServerSecretStore.ts";
import {
  CLOUD_LINKED_USER_ID,
  RELAY_ENVIRONMENT_CREDENTIAL_SECRET,
  RELAY_URL_SECRET,
} from "../../cloud/config.ts";
import { ServerEnvironment } from "../../environment/ServerEnvironment.ts";
import { OrchestrationEngineService } from "../../orchestration/Services/OrchestrationEngine.ts";
import { ProjectionSnapshotQuery } from "../../orchestration/Services/ProjectionSnapshotQuery.ts";
import { forkParked } from "../../serverActivation.ts";
import { InfinitusService } from "../Services/Infinitus.ts";
import { InfinitusTeamRelay } from "../Services/InfinitusTeamRelay.ts";
import {
  basename,
  buildFleetDocument,
  buildNowDocument,
  buildThreadsDocument,
  chunkLines,
  dayDigest,
  decideCommand,
  isExcluded,
  TRANSCRIPT_HISTORY_DAYS,
  transcriptRows,
  unixSeconds,
  viewText,
} from "./infinitusTeamRelay.logic.ts";
import { manifestHasVerb } from "./infinitusSignInLapse.logic.ts";

const NOW_INTERVAL = Duration.seconds(60);
const FULL_INTERVAL = Duration.seconds(300);
const POLL_INTERVAL = Duration.seconds(15);
/** Days of stats the Mac folds for the team. */
const STATS_DAYS = 30;
/** The whole thread, as the Mac read it. */
const TRANSCRIPT_TURN_LIMIT = 100_000;
const VIEW_TURN_LIMIT = 20;
/** The relay takes at most this many documents per publish. */
const DOCUMENTS_PER_PUBLISH = 40;

const decodeTeamDays = Schema.decodeUnknownOption(InfinitusTeamDays);

/**
 * The desktop's Team publisher and command runner on Infinitus Connect
 * (#1592; the port of the Mac's `TeamPublisher` and `TeamControlExecutor`).
 * Every cycle reads the link the way the alert relay does — the relay URL,
 * the environment credential and the linked user — then asks the relay
 * which teams that user is in and what each share allows, and publishes
 * from the thread shells, the Mac's snapshot and its `team-days` fold.
 * Nothing leaves for a kind whose share is `off`; a private project's
 * threads, live rows and transcripts stay home. Transcripts resume after
 * the relay's cursor for each thread and travel redacted, in chunks. While
 * the reply lists a grant for this machine the queue is polled: a command
 * is re-checked here and run through the orchestration engine, or refused,
 * and every one is acked. Any failure is a warning naming its stage; the
 * loops never end on one.
 */
export const InfinitusTeamRelayLive = Layer.effect(
  InfinitusTeamRelay,
  Effect.gen(function* () {
    const secrets = yield* ServerSecretStore.ServerSecretStore;
    const serverEnvironment = yield* ServerEnvironment;
    const snapshotQuery = yield* ProjectionSnapshotQuery;
    const engine = yield* OrchestrationEngineService;
    const infinitus = yield* InfinitusService;
    const httpClient = yield* HttpClient.HttpClient;
    const crypto = yield* Crypto.Crypto;
    const redact = makeRedactor({ home: NodeOS.homedir() });
    const machine = NodeOS.hostname().replace(/\.local$/, "");
    const serverCommandId = (tag: string) =>
      crypto.randomUUIDv4.pipe(Effect.map((uuid) => CommandId.make(`server:team-${tag}:${uuid}`)));

    /** The last memberships reply: the poller's grants and the `now`
        cycle's shares come from it. */
    let lastMemberships: TeamEnvironmentMemberships | null = null;
    /** The Mac's private projects, from the last `team-days` reply. */
    let exclusions: ReadonlyArray<string> = [];
    /** teamId → day → digest of the last stats document sent. */
    const sentDays = new Map<string, Map<string, string>>();
    /** teamId → threadId → the `updatedAt` whose rows were last handed
        over: a thread that has not moved is not read again. */
    const sentThreads = new Map<string, Map<string, number>>();

    const readSecretString = (name: string) =>
      secrets.get(name).pipe(
        Effect.map((bytes) =>
          Option.isSome(bytes) ? new TextDecoder().decode(bytes.value) : null,
        ),
        Effect.orElseSucceed(() => null),
      );

    const readLink = Effect.gen(function* () {
      const [url, credential, userId] = yield* Effect.all([
        readSecretString(RELAY_URL_SECRET),
        readSecretString(RELAY_ENVIRONMENT_CREDENTIAL_SECRET),
        readSecretString(CLOUD_LINKED_USER_ID),
      ]);
      if (!url || !credential || !userId) return null;
      const environmentId = yield* serverEnvironment.getEnvironmentId;
      const client = yield* HttpApiClient.make(RelayApi, {
        baseUrl: url,
        transformClient: HttpClient.mapRequest(
          HttpClientRequest.setHeader("authorization", `Bearer ${credential}`),
        ),
      }).pipe(Effect.provideService(HttpClient.HttpClient, httpClient));
      const headers = { authorization: `Bearer ${credential}` };
      return { userId, environmentId, headers, api: client.infinitusTeamEnvironment };
    });
    type Link = NonNullable<Effect.Success<typeof readLink>>;

    const memberships = (link: Link) =>
      link.api
        .memberships({
          params: { environmentId: link.environmentId },
          headers: { ...link.headers, [TEAM_USER_HEADER]: link.userId },
        })
        .pipe(Effect.tap((reply) => Effect.sync(() => void (lastMemberships = reply))));

    const publishDocuments = (
      link: Link,
      teamId: TeamEnvironmentMembership["teamId"],
      documents: ReadonlyArray<{ kind: "now" | "fleet" | "threads" | "stats"; key: string; body: unknown }>,
    ) =>
      Effect.forEach(
        Array.from({ length: Math.ceil(documents.length / DOCUMENTS_PER_PUBLISH) }, (_, i) =>
          documents.slice(i * DOCUMENTS_PER_PUBLISH, (i + 1) * DOCUMENTS_PER_PUBLISH),
        ),
        (batch) =>
          link.api.publishDocuments({
            params: { environmentId: link.environmentId, teamId },
            headers: link.headers,
            payload: { userId: link.userId, documents: batch },
          }),
        { discard: true },
      );

    const on = (share: TeamShareAudience) => share !== "off";
    const nowSeconds = DateTime.now.pipe(Effect.map((now) => Math.floor(DateTime.toEpochMillis(now) / 1000)));

    /** The Mac's snapshot when it answers, null when it does not. */
    const macSnapshot: Effect.Effect<InfinitusSnapshot | null> = infinitus.snapshot.pipe(
      Effect.map((snapshot) => (snapshot.available ? snapshot : null)),
    );

    /** `team-days --days 30`: the folded days and the exclusions; the
        exclusions memo keeps the last answer for the `now` cycle. Null
        when the Mac is away or too old for the verb. */
    const teamDays = (snapshot: InfinitusSnapshot | null) =>
      snapshot === null || !manifestHasVerb(snapshot.commands, "team-days")
        ? Effect.succeed(null)
        : infinitus
            .command({ command: "team-days", args: [], options: { days: String(STATS_DAYS) } })
            .pipe(
              Effect.map((reply) => Option.getOrNull(decodeTeamDays(reply))),
              Effect.tap((reply) =>
                Effect.sync(() => {
                  if (reply !== null) exclusions = reply.exclusions;
                }),
              ),
              Effect.catchCause((cause) =>
                Effect.logWarning("infinitus.team.days-failed", { cause: Cause.pretty(cause) }).pipe(
                  Effect.as(null),
                ),
              ),
            );

    const warn = (stage: string, extra: Record<string, unknown> = {}) =>
      Effect.catchCause((cause: Cause.Cause<unknown>) =>
        Effect.logWarning("infinitus.team.publish-failed", { stage, ...extra, cause: Cause.pretty(cause) }),
      );

    const shellSnapshot: Effect.Effect<OrchestrationShellSnapshot> = snapshotQuery
      .getShellSnapshot()
      .pipe(Effect.orDie);

    const nowDocument = (shell: OrchestrationShellSnapshot, snapshot: InfinitusSnapshot | null, at: number) =>
      buildNowDocument({
        at,
        machine,
        live: buildThreadsDocument(shell, { now: at, exclusions }).live,
        snapshot,
      });

    const publishNow = Effect.gen(function* () {
      const link = yield* readLink;
      if (link === null) return;
      const reply = yield* memberships(link);
      const teams = reply.teams.filter((team) => on(team.shares.now));
      if (teams.length === 0) return;
      const at = yield* nowSeconds;
      const body = nowDocument(yield* shellSnapshot, yield* macSnapshot, at);
      for (const team of teams) {
        yield* publishDocuments(link, team.teamId, [{ kind: "now", key: "-", body }]).pipe(
          warn("now", { teamId: team.teamId }),
        );
      }
    }).pipe(warn("memberships"));

    const publishTranscripts = (
      link: Link,
      team: TeamEnvironmentMembership,
      shell: OrchestrationShellSnapshot,
      at: number,
    ) =>
      Effect.gen(function* () {
        const floor = at - TRANSCRIPT_HISTORY_DAYS * 86_400;
        const sent = sentThreads.get(team.teamId) ?? new Map<string, number>();
        sentThreads.set(team.teamId, sent);
        const projects = new Map(shell.projects.map((project) => [project.id, project.workspaceRoot]));
        for (const thread of shell.threads) {
          const updatedAt = unixSeconds(thread.updatedAt) ?? at;
          if (updatedAt < floor || sent.get(thread.id) === updatedAt) continue;
          const root = projects.get(thread.projectId);
          const project = root === undefined ? thread.projectId : basename(root);
          if (isExcluded(project, exclusions)) continue;
          const detail = yield* snapshotQuery
            .getThreadDetailSnapshot(thread.id, { turnLimit: TRANSCRIPT_TURN_LIMIT })
            .pipe(Effect.orElseSucceed(() => Option.none()));
          if (Option.isNone(detail)) continue;
          const rows = transcriptRows(detail.value.thread.messages);
          const cursor = team.transcripts.find((entry) => entry.threadId === thread.id);
          const fresh = rows.slice(cursor?.rows ?? 0);
          let seq = cursor?.nextSeq ?? 0;
          for (const chunk of chunkLines(fresh, redact)) {
            yield* link.api.publishTranscript({
              params: { environmentId: link.environmentId, teamId: team.teamId },
              headers: link.headers,
              payload: { userId: link.userId, threadId: thread.id, seq, rows: chunk.rows, lines: chunk.lines },
            });
            seq += 1;
          }
          sent.set(thread.id, updatedAt);
        }
      });

    const publishAll = Effect.gen(function* () {
      const link = yield* readLink;
      if (link === null) return;
      const reply = yield* memberships(link);
      if (reply.teams.length === 0) return;
      const at = yield* nowSeconds;
      const snapshot = yield* macSnapshot;
      const days = yield* teamDays(snapshot);
      const shell = yield* shellSnapshot;
      const threads = buildThreadsDocument(shell, { now: at, exclusions });
      const now = buildNowDocument({ at, machine, live: threads.live, snapshot });
      const fleet = snapshot === null ? null : buildFleetDocument(snapshot.fleets, at);
      for (const team of reply.teams) {
        const documents: Array<{ kind: "now" | "fleet" | "threads" | "stats"; key: string; body: unknown }> = [];
        if (on(team.shares.now)) documents.push({ kind: "now", key: "-", body: now });
        if (on(team.shares.fleet) && fleet !== null) documents.push({ kind: "fleet", key: "-", body: fleet });
        if (on(team.shares.threads)) documents.push({ kind: "threads", key: "-", body: threads.document });
        const digests = sentDays.get(team.teamId) ?? new Map<string, string>();
        if (on(team.shares.stats) && days !== null) {
          for (const [day, body] of Object.entries(days.days)) {
            const digest = dayDigest(body);
            if (digests.get(day) === digest) continue;
            documents.push({ kind: "stats", key: day, body });
          }
        }
        if (documents.length > 0) {
          yield* publishDocuments(link, team.teamId, documents).pipe(
            Effect.tap(() =>
              Effect.sync(() => {
                for (const document of documents) {
                  if (document.kind === "stats") digests.set(document.key, dayDigest(document.body));
                }
                sentDays.set(team.teamId, digests);
              }),
            ),
            warn("documents", { teamId: team.teamId }),
          );
        }
        if (on(team.shares.transcripts)) {
          yield* publishTranscripts(link, team, shell, at).pipe(warn("transcripts", { teamId: team.teamId }));
        }
      }
    }).pipe(warn("memberships"));

    const nowIso = DateTime.now.pipe(Effect.map(DateTime.formatIso));

    const runCommand = (command: TeamQueuedCommand, shell: OrchestrationShellSnapshot) =>
      Effect.gen(function* () {
        const createdAt = yield* nowIso;
        const threadId = ThreadId.make(command.threadId);
        switch (command.action) {
          case "send": {
            yield* engine.dispatch({
              type: "thread.turn.start",
              commandId: yield* serverCommandId("send"),
              threadId,
              message: {
                messageId: MessageId.make(yield* crypto.randomUUIDv4),
                role: "user",
                text: command.text ?? "",
                attachments: [],
              },
              runtimeMode: DEFAULT_RUNTIME_MODE,
              interactionMode: "default",
              createdAt,
            });
            return { outcome: "done" as const };
          }
          case "interrupt": {
            yield* engine.dispatch({
              type: "thread.turn.interrupt",
              commandId: yield* serverCommandId("interrupt"),
              threadId,
              createdAt,
            });
            return { outcome: "done" as const };
          }
          case "view": {
            const detail = yield* snapshotQuery.getThreadDetailSnapshot(threadId, {
              turnLimit: VIEW_TURN_LIMIT,
            });
            if (Option.isNone(detail)) {
              return { outcome: "badRequest" as const, detail: "No such thread." };
            }
            return {
              outcome: "done" as const,
              result: { text: viewText(detail.value.thread.messages, redact) },
            };
          }
          case "new": {
            const wanted = (command.project ?? "").trim().toLowerCase();
            const project = shell.projects.find(
              (candidate) =>
                candidate.id.toLowerCase() === wanted || candidate.title.toLowerCase() === wanted,
            );
            if (project === undefined) {
              return { outcome: "badRequest" as const, detail: "No such project." };
            }
            if (project.defaultModelSelection === null) {
              return { outcome: "badRequest" as const, detail: "That project has no default model." };
            }
            const text = command.text ?? "";
            const newThreadId = ThreadId.make(yield* crypto.randomUUIDv4);
            yield* engine.dispatch({
              type: "thread.create",
              commandId: yield* serverCommandId("create"),
              threadId: newThreadId,
              projectId: project.id,
              title: text.length > 80 ? `${text.slice(0, 77)}…` : text,
              modelSelection: project.defaultModelSelection,
              runtimeMode: DEFAULT_RUNTIME_MODE,
              interactionMode: "default",
              branch: null,
              worktreePath: null,
              createdAt,
            });
            yield* engine.dispatch({
              type: "thread.turn.start",
              commandId: yield* serverCommandId("start"),
              threadId: newThreadId,
              message: {
                messageId: MessageId.make(yield* crypto.randomUUIDv4),
                role: "user",
                text,
                attachments: [],
              },
              runtimeMode: DEFAULT_RUNTIME_MODE,
              interactionMode: "default",
              createdAt,
            });
            return { outcome: "done" as const, result: { threadId: newThreadId } };
          }
        }
      });

    const pollCommands = Effect.gen(function* () {
      const reply = lastMemberships;
      if (reply === null || !reply.teams.some((team) => team.grants.length > 0)) return;
      const link = yield* readLink;
      if (link === null) return;
      const queued = yield* link.api.pollCommands({
        params: { environmentId: link.environmentId },
        headers: { ...link.headers, [TEAM_USER_HEADER]: link.userId },
      });
      if (queued.length === 0) return;
      const shell = yield* shellSnapshot;
      const live = new Set(
        buildThreadsDocument(shell, { now: yield* nowSeconds, exclusions }).live.map((row) => row.id),
      );
      const at = yield* nowIso;
      for (const command of queued) {
        const team = reply.teams.find((candidate) => candidate.teamId === command.teamId);
        const decision = decideCommand(command, {
          grants: team?.grants ?? [],
          liveThreadIds: live,
          nowIso: at,
        });
        const ack = decision.run
          ? yield* runCommand(command, shell).pipe(
              Effect.catchCause((cause) =>
                Effect.logWarning("infinitus.team.command-failed", {
                  commandId: command.commandId,
                  action: command.action,
                  cause: Cause.pretty(cause),
                }).pipe(Effect.as({ outcome: "refused" as const, detail: "It failed here." })),
              ),
            )
          : { outcome: decision.outcome, detail: decision.detail };
        yield* link.api
          .ackCommand({
            params: { environmentId: link.environmentId, commandId: command.commandId },
            headers: link.headers,
            payload: { userId: link.userId, ...ack },
          })
          .pipe(warn("ack", { commandId: command.commandId }));
        yield* Effect.logInfo("infinitus.team.command", {
          commandId: command.commandId,
          action: command.action,
          outcome: ack.outcome,
        });
      }
    }).pipe(warn("poll"));

    const start = () =>
      Effect.gen(function* () {
        yield* forkParked(
          Effect.sleep(Duration.seconds(5)).pipe(
            Effect.andThen(publishAll),
            Effect.andThen(publishAll.pipe(Effect.delay(FULL_INTERVAL), Effect.forever)),
          ),
        );
        yield* forkParked(
          publishNow.pipe(Effect.delay(NOW_INTERVAL), Effect.repeat(Schedule.spaced(NOW_INTERVAL))),
        );
        yield* forkParked(pollCommands.pipe(Effect.delay(POLL_INTERVAL), Effect.repeat(Schedule.spaced(POLL_INTERVAL))));
      });

    return { start, publishNow, publishAll, pollCommands };
  }),
);
