import { CommandId, MessageId, ThreadId, type TurnId } from "@t3tools/contracts";
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
 * Claude only: the adapter records an anchor (the last assistant uuid) per
 * completed turn in the resume cursor, keyed by the orchestration turn id so
 * it survives session restarts; nothing else has an addressable fork point
 * yet.
 */

const CLAUDE_DRIVER = "claudeAgent";

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
  if (input.turnCount < 1) return yield* refuse("Pick a turn to fork from.");

  const binding = yield* directory
    .getBinding(input.threadId)
    .pipe(Effect.mapError(() => refuse("The thread's provider session could not be read.")));
  if (Option.isNone(binding) || binding.value.provider !== CLAUDE_DRIVER) {
    return yield* refuse("Forking a thread needs a Claude session.");
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
  const seed = forkSeedMessages(source.value, input.turnCount);
  if (seed.length === 0) return yield* refuse("Nothing to fork at this turn.");

  const now = DateTime.formatIso(yield* DateTime.now);
  const threadId = ThreadId.make(yield* nextId);
  const cwd =
    binding.value.runtimePayload && typeof binding.value.runtimePayload === "object"
      ? (binding.value.runtimePayload as { cwd?: unknown }).cwd
      : undefined;

  // The binding first, so the thread never exists without its fork point;
  // insert-ignore keeps a concurrent real session's binding if one appears.
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
        resumeCursor: {
          threadId,
          resume: anchor.sessionId,
          resumeSessionAt: anchor.at,
          fork: true,
        },
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
      ...forkCreateFields(source.value, input),
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
    text: forkMarkerText({ title: source.value.title, id: source.value.id }, input.turnCount),
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
