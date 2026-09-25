/** Activity facts retained alongside Usage's incremental parse, never prompt/tool text. */
import * as Schema from "effect/Schema";
import type {
  StatsDay,
  StatsSession,
  ActivityTallyPayload,
  UsageProviderKind,
} from "@infinitus/contracts";
import { addStatsDays, compactStatsDay, statsDayFormatter } from "@infinitus/shared/stats";
import { cacheSavingsUsd, priceUsage, type RateTable } from "../usage/usagePricing.ts";
import type { CodexScanState, UsageRecord } from "../usage/usageTranscripts.ts";

const ActivityEvent = Schema.Struct({
  at: Schema.Finite,
  kind: Schema.Literals([
    "human",
    "phone",
    "agent",
    "nudge",
    "tool",
    "error",
    "denial",
    "end",
    "compaction",
    "retry",
    "context",
    "presence",
  ]),
  tool: Schema.optionalKey(Schema.String),
  label: Schema.optionalKey(Schema.String),
  model: Schema.optionalKey(Schema.String),
  effort: Schema.optionalKey(Schema.String),
});
type ActivityEvent = typeof ActivityEvent.Type;
export const TranscriptActivity = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  subagent: Schema.Boolean,
  events: Schema.Array(ActivityEvent),
  seen: Schema.Array(Schema.String),
});
export type TranscriptActivity = typeof TranscriptActivity.Type;
export function emptyTranscriptActivity(subagent = false): TranscriptActivity {
  return { sessionId: "", cwd: "", subagent, events: [], seen: [] };
}
const object = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
const text = (value: unknown) => (typeof value === "string" ? value : "");
const machinery =
  /^(\[Request interrupted|Stop hook feedback:|Caveat:|# Autonomous loop tick|\[1 prior \/loop|\(Re-invocation of \/|<)/;
function activityLabel(value: string): string | undefined {
  if (/\b(review|pull request|code review)\b/i.test(value)) return "review";
  if (/\b(test|tests|vitest|pytest|jest)\b/i.test(value)) return "tests";
  if (/\b(debug|troubleshoot|reproduce)\b/i.test(value)) return "debug";
  if (/\b(plan|design|architecture)\b/i.test(value)) return "plan";
  if (/\b(explain|explanation)\b/i.test(value)) return "explanation";
  return undefined;
}

export function activityCollector(initial: TranscriptActivity) {
  let sessionId = initial.sessionId;
  let cwd = initial.cwd;
  let subagent = initial.subagent;
  const events = [...initial.events];
  const seen = new Set(initial.seen);
  const reset = () => {
    sessionId = "";
    cwd = "";
    subagent = initial.subagent;
    events.length = 0;
    seen.clear();
  };
  const line = (raw: string, provider: UsageProviderKind, codex: CodexScanState) => {
    if (provider === "grok") return;
    if (provider === "claude" && !/"(?:user|assistant|system)"/.test(raw)) return;
    if (
      provider === "codex" &&
      (!/"(?:session_meta|turn_context|event_msg|response_item)"/.test(raw) ||
        raw.includes('"encrypted_content"'))
    )
      return;
    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      return;
    }
    const row = object(value),
      payload = object(row.payload),
      message = object(row.message);
    const at = Date.parse(text(row.timestamp));
    if (!Number.isFinite(at)) return;
    cwd = text(row.cwd) || text(payload.cwd) || cwd;
    sessionId = text(row.sessionId) || codex.sessionId || sessionId;
    const emit = (kind: ActivityEvent["kind"], extra: Omit<ActivityEvent, "at" | "kind"> = {}) =>
      events.push({ at, kind, ...extra });
    const unique = (key: string) => {
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    };
    const tool = (name: string, id: string, input: Record<string, unknown>) => {
      if (name === "wait" || (id && !unique("tool:" + id))) return;
      const command = text(input.command) || text(input.cmd);
      const path = text(input.file_path) || text(input.path);
      const label = /browser|playwright/i.test(name)
        ? "browser"
        : /simulator|xcode/i.test(name)
          ? "simulator"
          : activityLabel(command + " " + path);
      emit("tool", { tool: name || "unknown", ...(label ? { label } : {}) });
    };
    if (provider === "codex") {
      if (row.type === "session_meta") {
        subagent ||= !!object(object(payload.source).subagent).thread_spawn;
        return;
      }
      if (codex.suppressingForkCopies && at - codex.forkCopyAnchorMs < 1000) return;
      if (row.type === "turn_context") {
        emit("context", { model: text(payload.model), effort: text(payload.effort) || "unset" });
        return;
      }
      if (row.type === "event_msg") {
        switch (payload.type) {
          case "user_message": {
            const prompt = text(payload.message)
              .replace(/<system_instruction>[\s\S]*?<\/system_instruction>/g, "")
              .trim();
            if (prompt) emit("human", { label: activityLabel(prompt) ?? "code" });
            break;
          }
          case "task_complete":
          case "turn_aborted":
            emit("end");
            break;
          case "context_compacted":
            emit("compaction");
            break;
          case "web_search_end":
            tool("web_search", text(payload.call_id), {});
            break;
          case "patch_apply_end":
            if (payload.success === false) emit("error");
            break; // apply_patch is already counted by its function/custom call.
        }
      } else if (row.type === "response_item") {
        if (payload.type === "function_call" || payload.type === "custom_tool_call") {
          let input: Record<string, unknown> = {};
          try {
            input = object(JSON.parse(text(payload.arguments)));
          } catch {
            input = { command: text(payload.input) };
          }
          tool(text(payload.name), text(payload.call_id), input);
        }
      }
      return;
    }
    if (row.type === "system") {
      if (row.subtype === "compact_boundary") emit("compaction");
      return;
    }
    if (row.uuid && !unique("line:" + text(row.uuid))) return;
    const content = message.content;
    const blocks = Array.isArray(content) ? content.map(object) : [];
    if (row.type === "user") {
      if (row.toolDenialKind) emit("denial");
      if (blocks.some((b) => b.type === "tool_result")) {
        for (const b of blocks) if (b.type === "tool_result" && b.is_error === true) emit("error");
      } else if (row.isCompactSummary === true) emit("compaction");
      else {
        const prompt =
          typeof content === "string"
            ? content
            : blocks
                .filter((b) => b.type === "text")
                .map((b) => text(b.text))
                .join("\n");
        if (prompt.startsWith("[Infinitus] The user sent this from their phone")) emit("phone");
        else if (prompt.startsWith("[Infinitus]")) emit("nudge");
        else if (
          prompt.startsWith("Another Claude session sent a message") ||
          prompt.startsWith("<teammate-message")
        )
          emit("agent");
        else if (prompt.trim() && !machinery.test(prompt))
          emit("human", { label: activityLabel(prompt) ?? "code" });
      }
    } else if (row.type === "assistant") {
      if (row.isApiErrorMessage === true) emit("retry");
      emit("context", { model: text(message.model), effort: text(row.effort) || "unset" });
      for (const b of blocks)
        if (b.type === "tool_use") tool(text(b.name), text(b.id), object(b.input));
      if (
        message.stop_reason === "end_turn" ||
        (blocks.some((b) => b.type === "text") && !blocks.some((b) => b.type === "tool_use"))
      )
        emit("end");
      else emit("presence");
    }
  };
  return {
    reset,
    line,
    finish: (): TranscriptActivity => ({ sessionId, cwd, subagent, events, seen: [...seen] }),
  };
}

/** Price at query time, so a refreshed price or custom override reprices saved history. */
export function summarizeStatsSession(input: {
  id: string;
  sourceId: string;
  updatedAt: number;
  activity: TranscriptActivity;
  records: readonly UsageRecord[];
  provider: UsageProviderKind;
  timeZone: string;
  sinceDay: string;
  untilDay: string;
  rates: RateTable;
  overrides: RateTable;
}): StatsSession {
  const dayKey = statsDayFormatter(input.timeZone);
  const days = new Map<string, StatsDay>();
  const spans = new Map<string, [number, number]>();
  const minutes = new Map<number, number>();
  const add = (key: string, day: StatsDay) => {
    if (key >= input.sinceDay && key <= input.untilDay)
      days.set(key, addStatsDays(days.get(key) ?? {}, day));
  };
  let model = "unknown",
    effort = "unset",
    toolsSinceHuman = 0,
    endedAt: number | null = null;
  let stretch: { at: number; last: number; label: string; tally: ActivityTallyPayload } | null =
    null;
  const flush = () => {
    if (!stretch) return;
    const tally = { ...stretch.tally, n: 1, s: Math.max(0, stretch.last - stretch.at) / 1000 };
    add(dayKey(stretch.at), {
      activities: { [stretch.label]: tally },
      byModel: { [model]: { n: 1, s: tally.s } },
      byEngine: { [input.provider]: { n: 1, s: tally.s } },
      byEffort: { [effort]: { n: 1, s: tally.s } },
    });
    stretch = null;
  };
  const rows = [
    ...input.activity.events.map((event) => ({ at: event.at, event, usage: null })),
    ...input.records.map((usage) => ({ at: usage.timestampMs, event: null, usage })),
  ].sort((a, b) => a.at - b.at);
  for (const row of rows) {
    const key = dayKey(row.at);
    if (key > input.untilDay) continue;
    if (!input.activity.subagent) {
      const span = spans.get(key);
      spans.set(
        key,
        span ? [Math.min(span[0], row.at), Math.max(span[1], row.at)] : [row.at, row.at],
      );
    }
    if (stretch) stretch.last = row.at;
    if (row.usage) {
      const record = row.usage;
      model = record.model;
      const priced = priceUsage(input.rates, record, input.overrides);
      const savings = cacheSavingsUsd(input.rates, record, input.overrides);
      const unpriced = priced.costSource === "unpriced" ? 1 : 0;
      const tally = {
        in: record.totals.uncachedInputTokens,
        out: record.totals.outputTokens,
        cr: record.totals.cachedInputTokens,
        cw: record.totals.cacheCreationTokens,
        usd: priced.costUsd,
        sv: savings,
        unpriced,
      };
      add(key, {
        inputTokens: tally.in,
        outputTokens: tally.out,
        cacheReadTokens: tally.cr,
        cacheWriteTokens: tally.cw,
        usd: tally.usd,
        cacheSavingsUSD: savings,
        unpricedRecords: unpriced,
        pricedRecords: 1 - unpriced,
        byModel: { [model]: tally },
        byEngine: { [input.provider]: tally },
        byEffort: { [effort]: tally },
      });
      if (key >= input.sinceDay && tally.out > 0) {
        const minute = Math.floor(row.at / 60000);
        minutes.set(minute, (minutes.get(minute) ?? 0) + tally.out);
      }
      if (stretch)
        stretch.tally = {
          ...stretch.tally,
          in: (stretch.tally.in ?? 0) + tally.in,
          out: (stretch.tally.out ?? 0) + tally.out,
          cr: (stretch.tally.cr ?? 0) + tally.cr,
          cw: (stretch.tally.cw ?? 0) + tally.cw,
          usd: (stretch.tally.usd ?? 0) + tally.usd,
          unpriced: (stretch.tally.unpriced ?? 0) + unpriced,
        };
      continue;
    }
    const event = row.event!;
    switch (event.kind) {
      case "context":
        model = event.model || model;
        effort = event.effort || effort;
        break;
      case "human":
      case "phone":
      case "agent":
      case "nudge":
        if (input.activity.subagent) break;
        flush();
        stretch = { at: event.at, last: event.at, label: event.label ?? "code", tally: {} };
        add(
          key,
          event.kind === "human"
            ? { humanMessages: 1 }
            : event.kind === "phone"
              ? { phoneMessages: 1 }
              : event.kind === "agent"
                ? { agentMessages: 1 }
                : { nudges: 1 },
        );
        if (event.kind === "human" || event.kind === "phone") {
          add(key, {
            longestUnattended: toolsSinceHuman,
            ...(endedAt === null
              ? {}
              : { waitingSeconds: Math.min(8 * 3600, Math.max(0, event.at - endedAt) / 1000) }),
          });
          toolsSinceHuman = 0;
        }
        endedAt = null;
        break;
      case "tool":
        add(key, {
          toolCalls: { [event.tool ?? "unknown"]: 1 },
          ...(/^(Agent|Task|spawn_agent)$/.test(event.tool ?? "") ? { subagents: 1 } : {}),
        });
        if (!input.activity.subagent) {
          toolsSinceHuman++;
          add(key, { longestUnattended: toolsSinceHuman });
          if (/AskUserQuestion|request_user_input/.test(event.tool ?? ""))
            add(key, { questions: 1 });
          if (stretch && event.label) stretch.label = event.label;
        }
        break;
      case "end":
        if (!input.activity.subagent && endedAt === null) {
          add(key, { turns: 1 });
          endedAt = event.at;
        }
        break;
      case "error":
        add(key, { toolErrors: 1 });
        break;
      case "denial":
        add(key, { denials: 1 });
        break;
      case "compaction":
        add(key, { compactions: 1 });
        break;
      case "retry":
        add(key, { retries: 1 });
        break;
      case "presence":
        break;
    }
  }
  flush();
  for (const [key, [first, last]] of spans) {
    const seconds = Math.max(0, last - first) / 1000;
    const buckets = [0, 0, 0, 0];
    buckets[seconds < 900 ? 0 : seconds < 3600 ? 1 : seconds < 14400 ? 2 : 3] = 1;
    add(key, { sessions: [input.id], sessionSeconds: seconds, sessionBuckets: buckets });
  }
  return {
    id: input.id,
    sourceId: input.sourceId,
    updatedAt: input.updatedAt,
    days: [...days].map(([key, day]) => ({ key, day: compactStatsDay(day) })),
    minutes: [...minutes],
  };
}
