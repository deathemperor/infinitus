import type { InfinitusManifestCommand } from "@t3tools/contracts/infinitus";
import type { AgentAwarenessPhase } from "@t3tools/shared/agentAwareness";
import * as Schema from "effect/Schema";

/**
 * Push bridge (#269 G), the pure half. A thread phase the Mac's `push` verb
 * takes on the request line's `secret` field (the manifest says `stdin:
 * "payload"`): `{kind: "thread.phase", threadId, title, phase, local:
 * false}`, which native words ("<title>: waiting for approval") and fans
 * out to the phone's alert token and the Slack / Telegram away channels;
 * `local: false` skips the Mac's own Notification Center notice, since the
 * desktop already shows a banner for these phases (#270 B); `slack: false`
 * (#1028) skips the Mac's Slack webhook post alone, for a thread the Slack
 * bridge (#574) already reports in a Slack thread of its own. Only the
 * phases a person acts on are worth a push: the two waits and the two ends.
 * `starting` / `running` / `stale` are noise.
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
  local: Schema.Literal(false),
  slack: Schema.optional(Schema.Literal(false)),
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

/** The JSON line the verb takes on `secret`; `skipSlack` adds `slack: false`. */
export function threadPhasePayload(input: {
  readonly threadId: string;
  readonly title: string;
  readonly phase: AgentAwarenessPhase;
  readonly skipSlack?: boolean;
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
    local: false,
    ...(input.skipSlack === true ? { slack: false as const } : {}),
  });
}

/**
 * The verb, taking a payload on stdin whose summary names the `local` flag,
 * is in the manifest. An app older than the flag would post its own notice
 * beside the desktop's banner, so it gets no push at all rather than two.
 */
export function manifestHasPush(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some(
    (command) =>
      command.name === "push" && command.stdin === "payload" && command.summary.includes("local"),
  );
}

/**
 * The push summary names the `slack` flag (#1028; before it the summary
 * said only "Slack/Telegram", capitalized). An older app ignores an unknown
 * key, so the flag is simply not sent to it.
 */
export function manifestPushSkipsSlack(commands: ReadonlyArray<InfinitusManifestCommand>): boolean {
  return commands.some((command) => command.name === "push" && command.summary.includes("slack"));
}
