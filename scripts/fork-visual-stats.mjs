/** Seed real Claude/Codex transcripts for the portable Stats visual pass. */
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";

const baseDir = NodeProcess.argv[2];
if (!baseDir) throw new Error("usage: fork-visual-stats.mjs <disposable-base-dir>");
const stateDir = NodePath.join(baseDir, "userdata");
const claudeHome = NodePath.join(baseDir, "claude");
const codexHome = NodePath.join(baseDir, "codex");
const claudeDir = NodePath.join(claudeHome, "projects", "fixture");
const codexDir = NodePath.join(codexHome, "sessions");
await Promise.all(
  [stateDir, claudeDir, codexDir].map((dir) => NodeFSP.mkdir(dir, { recursive: true })),
);
const now = Date.now();
const midnight = new Date(now).setUTCHours(0, 0, 0, 0);
const timestamp = (minute) => new Date(midnight + minute * 60_000).toISOString();
const jsonl = (rows) => rows.map((row) => JSON.stringify(row)).join("\n") + "\n";
await NodeFSP.writeFile(
  NodePath.join(stateDir, "settings.json"),
  JSON.stringify({
    providers: { claudeAgent: { homePath: claudeHome }, codex: { homePath: codexHome } },
  }),
);
await NodeFSP.writeFile(
  NodePath.join(stateDir, "usage-model-rates.json"),
  JSON.stringify({
    fetchedAtMs: now,
    document: {
      "claude-visual-fixture": { input_cost_per_token: 0.000001, output_cost_per_token: 0.00001 },
      "gpt-visual-fixture": { input_cost_per_token: 0.000001, output_cost_per_token: 0.00001 },
    },
  }),
);
await NodeFSP.writeFile(
  NodePath.join(claudeDir, "visual-claude.jsonl"),
  jsonl([
    {
      type: "user",
      timestamp: timestamp(0),
      sessionId: "visual-claude",
      message: { content: "Plan this change" },
    },
    {
      type: "assistant",
      timestamp: timestamp(1),
      sessionId: "visual-claude",
      requestId: "visual-request",
      message: {
        id: "visual-message",
        model: "claude-visual-fixture",
        usage: { input_tokens: 1000, output_tokens: 1000 },
        content: [{ type: "tool_use", id: "visual-tool", name: "AskUserQuestion", input: {} }],
      },
    },
    {
      type: "user",
      timestamp: timestamp(2),
      sessionId: "visual-claude",
      message: { content: "[Infinitus] Continue" },
    },
    {
      type: "assistant",
      timestamp: timestamp(3),
      sessionId: "visual-claude",
      message: {
        model: "claude-visual-fixture",
        stop_reason: "end_turn",
        content: [{ type: "text", text: "Done" }],
      },
    },
  ]),
);
await NodeFSP.writeFile(
  NodePath.join(codexDir, "visual-codex.jsonl"),
  jsonl([
    { type: "session_meta", timestamp: timestamp(0), payload: { id: "visual-codex" } },
    {
      type: "turn_context",
      timestamp: timestamp(0),
      payload: { model: "gpt-visual-fixture", effort: "high" },
    },
    {
      type: "event_msg",
      timestamp: timestamp(0),
      payload: { type: "user_message", message: "Implement this change" },
    },
    {
      type: "event_msg",
      timestamp: timestamp(1),
      payload: {
        type: "token_count",
        info: { last_token_usage: { input_tokens: 2000, output_tokens: 1000 } },
      },
    },
    { type: "event_msg", timestamp: timestamp(2), payload: { type: "task_complete" } },
  ]),
);
