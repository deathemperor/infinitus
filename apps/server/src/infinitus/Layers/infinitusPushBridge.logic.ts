import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import type { AgentAwarenessPhase } from "@t3tools/shared/agentAwareness";
import * as Schema from "effect/Schema";

/**
 * Push bridge (#269 G), the pure half. A thread phase the Mac's `push` verb
 * takes on the request line's `secret` field (the manifest says `stdin:
 * "payload"`): `{kind: "thread.phase", threadId, title, phase}`, which
 * native words ("<title>: waiting for approval") and fans out to the
 * Notification Center, the phone's alert token and the Slack / Telegram
 * away channels. Only the phases a person acts on are worth a push: the
 * two waits and the two ends. `starting` / `running` / `stale` are noise.
 */

const PUSHED_PHASES: ReadonlySet<AgentAwarenessPhase> = new Set<AgentAwarenessPhase>([
  "waiting_for_approval",
  "waiting_for_input",
  "completed",
  "failed",
]);

/** Titles are user prose; the Mac's line has room for about this much. */
export const MAX_PUSH_TITLE_LENGTH = 120;

const ThreadPhasePush = Schema.Struct({
  kind: Schema.Literal("thread.phase"),
  threadId: Schema.String,
  title: Schema.String,
  phase: Schema.String,
});
const encodePush = Schema.encodeSync(Schema.fromJsonString(ThreadPhasePush));

/**
 * Whether a thread that moved from `previous` to `phase` is pushed: only a
 * change into a pushed phase, and only for a thread whose phase was already
 * recorded — the first sighting (a boot, a thread the server had not seen
 * change yet) seeds the record and pushes nothing, so a restart never
 * announces "finished" for every idle thread.
 */
export function shouldPushPhase(
  previous: AgentAwarenessPhase | undefined,
  phase: AgentAwarenessPhase,
): boolean {
  return previous !== undefined && previous !== phase && PUSHED_PHASES.has(phase);
}

/** The JSON line the verb takes on `secret`. */
export function threadPhasePayload(input: {
  readonly threadId: string;
  readonly title: string;
  readonly phase: AgentAwarenessPhase;
}): string {
  const trimmed = input.title.trim();
  return encodePush({
    kind: "thread.phase",
    threadId: input.threadId,
    title:
      trimmed.length > MAX_PUSH_TITLE_LENGTH
        ? `${trimmed.slice(0, MAX_PUSH_TITLE_LENGTH - 1)}…`
        : trimmed,
    phase: input.phase,
  });
}

/** The verb, taking a payload on stdin, is in the manifest (native since the `push` verb landed). */
export function manifestHasPush(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "push" && command.stdin === "payload");
}
