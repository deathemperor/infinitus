import { CommandId, MessageId, ThreadId, TurnId } from "@t3tools/contracts";
import {
  InfinitusThreadForkInput,
  InfinitusThreadForkRefused,
  InfinitusThreadForkResult,
} from "@t3tools/contracts/infinitus";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";

import * as OrchestrationEngine from "../orchestration/Services/OrchestrationEngine.ts";
import * as ProjectionSnapshotQuery from "../orchestration/Services/ProjectionSnapshotQuery.ts";
import * as ProviderSessionDirectory from "../provider/Services/ProviderSessionDirectory.ts";

/**
 * Fork a thread at a turn (#270 E2). The new thread sits on the source's
 * branch and worktree, shows the source's messages up to that turn behind a
 * provenance marker (a history import, so no checkpoints and no turn), and
 * its provider binding points at the source's Claude session with the turn's
 * anchor as `resumeSessionAt` and `fork: true`, so the first turn forks the
 * session there instead of continuing it. The source thread is not touched.
 *
 * Claude: the adapter records an anchor (the last assistant uuid) per
 * completed turn in the resume cursor, keyed by the orchestration turn id so
 * it survives session restarts. Codex (#819): the orchestration turn id on a
 * Codex thread is Codex's own turn id (the runtime mints it from
 * `turn/started`), so a checkpoint's turn id is the `lastTurnId` of
 * `thread/fork`; the binding names the source's Codex thread with
 * `fork: true` and that turn. Other drivers have no addressable fork point.
 */

const CLAUDE_DRIVER = "claudeAgent";
const CODEX_DRIVER = "codex";

/** The anchor a Claude resume cursor carries for a turn, or none. */
export function claudeForkAnchor(
  resumeCursor: unknown,
  turnId: TurnId,
): { readonly sessionId: string; readonly at: string } | null {
  if (!resumeCursor || typeof resumeCursor !== "object") return null;
  const cursor = resumeCursor as { resume?: unknown; anchors?: unknown };
  if (typeof cursor.resume !== "string" || !Array.isArray(cursor.anchors)) return null;
  for (const anchor of cursor.anchors as ReadonlyArray<unknown>) {
    if (!anchor || typeof anchor !== "object") continue;
    const candidate = anchor as { turnId?: unknown; at?: unknown };
    if (
      candidate.turnId === turnId &&
      typeof candidate.at === "string" &&
      candidate.at.length > 0
    ) {
      return { sessionId: cursor.resume, at: candidate.at };
    }
  }
  return null;
}

/**
 * The session's latest completed turn as a fork point (#269 C): the last
 * anchor, with every anchored turn id so the seed can keep exactly the
 * completed turns. Null when no turn has completed in this session.
 */
export function latestClaudeForkAnchor(resumeCursor: unknown): {
  readonly sessionId: string;
  readonly at: string;
  readonly turnCount: number;
  readonly turnIds: ReadonlySet<TurnId>;
} | null {
  if (!resumeCursor || typeof resumeCursor !== "object") return null;
  const cursor = resumeCursor as { resume?: unknown; anchors?: unknown };
  if (typeof cursor.resume !== "string" || !Array.isArray(cursor.anchors)) return null;
  const anchors: Array<{ turnId: TurnId; at: string }> = [];
  for (const anchor of cursor.anchors as ReadonlyArray<unknown>) {
    if (!anchor || typeof anchor !== "object") continue;
    const candidate = anchor as { turnId?: unknown; at?: unknown };
    if (
      typeof candidate.turnId === "string" &&
      candidate.turnId.length > 0 &&
      typeof candidate.at === "string" &&
      candidate.at.length > 0
    ) {
      anchors.push({ turnId: TurnId.make(candidate.turnId), at: candidate.at });
    }
  }
  const last = anchors.at(-1);
  if (last === undefined) return null;
  return {
    sessionId: cursor.resume,
    at: last.at,
    turnCount: anchors.length,
    turnIds: new Set(anchors.map((anchor) => anchor.turnId)),
  };
}

/** The Codex thread a Codex resume cursor names, or none. */
function codexThreadIdOf(resumeCursor: unknown): string | null {
  if (!resumeCursor || typeof resumeCursor !== "object") return null;
  const cursor = resumeCursor as { threadId?: unknown };
  return typeof cursor.threadId === "string" && cursor.threadId.length > 0 ? cursor.threadId : null;
}

/** The fork point of a Codex thread at a turn (#819): its own thread and the turn id. */
export function codexForkPoint(
  resumeCursor: unknown,
  turnId: TurnId,
): { readonly threadId: string; readonly lastTurnId: string } | null {
  const threadId = codexThreadIdOf(resumeCursor);
  return threadId === null ? null : { threadId, lastTurnId: turnId };
}

/**
 * The latest completed turn of a Codex thread as a fork point (#819, for a
 * side question): the thread's latest turn once it has completed, with every
 * turn the messages name so the seed keeps them all — nothing runs, so they
 * are all done. Null while no turn has completed, or one is running.
 */
export function latestCodexForkPoint(
  resumeCursor: unknown,
  thread: {
    readonly latestTurn: { readonly turnId: TurnId; readonly state: string } | null;
    readonly messages: ReadonlyArray<{ readonly turnId: TurnId | null }>;
  },
): {
  readonly threadId: string;
  readonly lastTurnId: string;
  readonly turnCount: number;
  readonly turnIds: ReadonlySet<TurnId>;
} | null {
  const threadId = codexThreadIdOf(resumeCursor);
  if (threadId === null || thread.latestTurn === null) return null;
  if (thread.latestTurn.state !== "completed") return null;
  const turnIds = new Set(
    thread.messages.flatMap((message) => (message.turnId === null ? [] : [message.turnId])),
  );
  turnIds.add(thread.latestTurn.turnId);
  return { threadId, lastTurnId: thread.latestTurn.turnId, turnCount: turnIds.size, turnIds };
}

/** The source's user and assistant messages up to the turn, in order. */
export interface ForkSeedSource {
  readonly messages: ReadonlyArray<{
    readonly role: string;
    readonly text: string;
    readonly turnId: TurnId | null;
    readonly createdAt: string;
  }>;
  readonly checkpoints: ReadonlyArray<{
    readonly turnId: TurnId;
    readonly checkpointTurnCount: number;
    readonly completedAt: string;
  }>;
}

export function forkSeedMessages(
  thread: ForkSeedSource,
  turnCount: number,
): ReadonlyArray<{ role: "user" | "assistant"; text: string; createdAt: string }> {
  const checkpoint = thread.checkpoints.find(
    (candidate) => candidate.checkpointTurnCount === turnCount,
  );
  if (!checkpoint) return [];
  const keptTurnIds = new Set(
    thread.checkpoints
      .filter((candidate) => candidate.checkpointTurnCount <= turnCount)
      .map((candidate) => candidate.turnId),
  );
  return thread.messages
    .filter(
      (message) =>
        (message.role === "user" || message.role === "assistant") &&
        message.text.trim().length > 0 &&
        // Turn-attributed messages by turn; imported or unattributed ones by time.
        (message.turnId === null
          ? message.createdAt <= checkpoint.completedAt
          : keptTurnIds.has(message.turnId)),
    )
    .map((message) => ({
      role: message.role === "user" ? "user" : "assistant",
      text: message.text,
      createdAt: message.createdAt,
    }));
}

/**
 * The seed of a fork at the latest completed turn (#269 C): the messages of
 * the completed turns, plus unattributed ones (imported history); a running
 * turn's messages carry its own id and stay out.
 */
export function forkSeedMessagesByTurns(
  thread: Pick<ForkSeedSource, "messages">,
  turnIds: ReadonlySet<TurnId>,
): ReadonlyArray<{ role: "user" | "assistant"; text: string; createdAt: string }> {
  return thread.messages
    .filter(
      (message) =>
        (message.role === "user" || message.role === "assistant") &&
        message.text.trim().length > 0 &&
        (message.turnId === null || turnIds.has(message.turnId)),
    )
    .map((message) => ({
      role: message.role === "user" ? "user" : "assistant",
      text: message.text,
      createdAt: message.createdAt,
    }));
}

export function forkMarkerText(source: { title: string; id: ThreadId }, turnCount: number) {
  return `Forked from **${source.title}** at turn ${turnCount} (thread \`${source.id}\`).`;
}

/**
 * Fork (#269 C): what a side question changes about the new thread — it
 * asks in plan mode (read-only) and carries `sideOf`, so the lists hide it
 * and the drawer finds it. A plain fork keeps the source's mode.
 */
export function forkCreateFields<Mode extends string>(
  source: { readonly id: ThreadId; readonly title: string; readonly interactionMode: Mode },
  input: { readonly turnCount: number; readonly side?: true | undefined },
): { readonly title: string; readonly interactionMode: Mode | "plan"; readonly sideOf?: ThreadId } {
  return input.side === true
    ? { title: `Side question: ${source.title}`, interactionMode: "plan", sideOf: source.id }
    : {
        title: `${source.title} (fork at turn ${input.turnCount})`,
        interactionMode: source.interactionMode,
      };
}

export const forkThreadAtTurn = Effect.fn("forkThreadAtTurn")(function* (
  input: InfinitusThreadForkInput,
) {
  const engine = yield* OrchestrationEngine.OrchestrationEngineService;
  const snapshots = yield* ProjectionSnapshotQuery.ProjectionSnapshotQuery;
  const directory = yield* ProviderSessionDirectory.ProviderSessionDirectory;
  const crypto = yield* Crypto.Crypto;

  const refuse = (reason: string) => new InfinitusThreadForkRefused({ reason });
  // A failing platform RNG is a defect, not a reason the user can act on.
  const nextId = crypto.randomUUIDv4.pipe(Effect.orDie);

  const source = yield* snapshots
    .getThreadDetailById(input.threadId)
    .pipe(Effect.mapError(() => refuse("The thread could not be read.")));
  if (Option.isNone(source)) return yield* refuse("The thread was not found.");
  if (input.turnCount !== undefined && input.turnCount < 1) {
    return yield* refuse("Pick a turn to fork from.");
  }

  const binding = yield* directory
    .getBinding(input.threadId)
    .pipe(Effect.mapError(() => refuse("The thread's provider session could not be read.")));
  if (
    Option.isNone(binding) ||
    (binding.value.provider !== CLAUDE_DRIVER && binding.value.provider !== CODEX_DRIVER)
  ) {
    return yield* refuse("Forking a thread needs a Claude or Codex session.");
  }
  const point = yield* Effect.gen(function* () {
    if (binding.value.provider === CODEX_DRIVER) {
      if (input.turnCount === undefined) {
        const latest = latestCodexForkPoint(binding.value.resumeCursor, source.value);
        if (latest === null) {
          return yield* refuse("Ask a side question once a turn has completed.");
        }
        return {
          cursor: { threadId: latest.threadId, fork: true, lastTurnId: latest.lastTurnId },
          turnCount: latest.turnCount,
          seed: forkSeedMessagesByTurns(source.value, latest.turnIds),
        };
      }
      const checkpoint = source.value.checkpoints.find(
        (candidate) => candidate.checkpointTurnCount === input.turnCount,
      );
      if (!checkpoint) return yield* refuse("Nothing to fork at this turn.");
      const at = codexForkPoint(binding.value.resumeCursor, checkpoint.turnId);
      if (at === null) return yield* refuse("The thread has no Codex session to fork.");
      return {
        cursor: { threadId: at.threadId, fork: true, lastTurnId: at.lastTurnId },
        turnCount: input.turnCount,
        seed: forkSeedMessages(source.value, input.turnCount),
      };
    }
    if (input.turnCount === undefined) {
      // Fork (#269 C): a side question takes the session's latest completed
      // turn from its own anchors. A checkpoint needs a git repository; a
      // thread in a plain directory never has one, an anchor it always has.
      const latest = latestClaudeForkAnchor(binding.value.resumeCursor);
      if (latest === null) {
        return yield* refuse("Ask a side question once a turn has completed.");
      }
      return {
        cursor: { resume: latest.sessionId, resumeSessionAt: latest.at, fork: true },
        turnCount: latest.turnCount,
        seed: forkSeedMessagesByTurns(source.value, latest.turnIds),
      };
    }
    const checkpoint = source.value.checkpoints.find(
      (candidate) => candidate.checkpointTurnCount === input.turnCount,
    );
    if (!checkpoint) return yield* refuse("Nothing to fork at this turn.");
    const anchor = claudeForkAnchor(binding.value.resumeCursor, checkpoint.turnId);
    if (anchor === null) {
      return yield* refuse(
        "No fork point was recorded for this turn; turns completed before forking existed cannot be forked.",
      );
    }
    return {
      cursor: { resume: anchor.sessionId, resumeSessionAt: anchor.at, fork: true },
      turnCount: input.turnCount,
      seed: forkSeedMessages(source.value, input.turnCount),
    };
  });
  const { cursor, turnCount, seed } = point;
  if (seed.length === 0) return yield* refuse("Nothing to fork at this turn.");

  const now = DateTime.formatIso(yield* DateTime.now);
  const threadId = ThreadId.make(yield* nextId);
  const cwd =
    binding.value.runtimePayload && typeof binding.value.runtimePayload === "object"
      ? (binding.value.runtimePayload as { cwd?: unknown }).cwd
      : undefined;

  // The binding first, so the thread never exists without its fork point;
  // insert-ignore keeps a concurrent real session's binding if one appears.
  // A Claude cursor carries the new thread's id (the source session is
  // `resume`); a Codex cursor's `threadId` is the source's Codex thread.
  yield* directory
    .upsert(
      {
        threadId,
        provider: binding.value.provider,
        ...(binding.value.providerInstanceId
          ? { providerInstanceId: binding.value.providerInstanceId }
          : {}),
        status: "stopped",
        runtimeMode: source.value.runtimeMode,
        resumeCursor: "resume" in cursor ? { threadId, ...cursor } : cursor,
        ...(typeof cwd === "string" ? { runtimePayload: { cwd } } : {}),
      },
      { onConflict: "ignore" },
    )
    .pipe(Effect.mapError((error) => refuse(error.message)));

  yield* engine
    .dispatch({
      type: "thread.create",
      commandId: CommandId.make(yield* nextId),
      threadId,
      projectId: source.value.projectId,
      ...forkCreateFields(source.value, { turnCount, ...(input.side ? { side: true } : {}) }),
      modelSelection: source.value.modelSelection,
      runtimeMode: source.value.runtimeMode,
      branch: source.value.branch,
      worktreePath: source.value.worktreePath,
      createdAt: now,
      historyImport: true,
    })
    .pipe(Effect.mapError((error) => refuse(error.message)));

  const marker = {
    role: "assistant" as const,
    text: forkMarkerText({ title: source.value.title, id: source.value.id }, turnCount),
    createdAt: now,
  };
  yield* engine
    .dispatch({
      type: "thread.history.import",
      commandId: CommandId.make(yield* nextId),
      threadId,
      messages: [marker, ...seed].map((message, index) => ({
        messageId: MessageId.make(`${threadId}:${String(index).padStart(6, "0")}`),
        ...message,
      })),
    })
    .pipe(Effect.mapError((error) => refuse(error.message)));

  return { threadId } satisfies InfinitusThreadForkResult;
});
