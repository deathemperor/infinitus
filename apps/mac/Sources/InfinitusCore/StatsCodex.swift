import Foundation

/// Codex CLI transcripts (issue #24, "later" list): one rollout file per
/// session under `~/.codex/sessions/YYYY/MM/DD/`, a JSON object per
/// line with a `type` and a `payload`. The same `FileEntry` / `Stretch`
/// model as the Claude reader, fed from a different vocabulary:
///
/// - `session_meta` — the cwd.
/// - `turn_context` — the model and effort every later token count
///   belongs to (the counts don't carry them).
/// - `event_msg.user_message` — the person typed: a human message, a
///   stretch boundary. `<system_instruction>` blocks are a host app's
///   preamble (Conductor), not the person; what's left outside them is.
/// - `event_msg.token_count` — one response's usage in
///   `info.last_token_usage`; `total_token_usage` is the running sum.
///   OpenAI's `input_tokens` includes the cached part, so the uncached
///   share is what counts as input here (Claude's `input_tokens` is
///   uncached too); `output_tokens` already includes reasoning.
/// - `response_item.function_call` / `custom_tool_call` — a tool call;
///   `exec`/`shell`/`exec_command` run commands, so their text feeds the
///   command-shaped signals (simulator, review).
/// - `event_msg.patch_apply_end` — the edits, one per changed path.
/// - `event_msg.task_complete` — the turn ended in prose; `turn_aborted`
///   ends it too (the person pulled the brake).
/// - `event_msg.context_compacted` — a compaction.
///
/// OpenAI models have no entry in the price table, so their tokens are
/// counted and their spend stays $0 — shown as unpriced, never guessed.
public enum StatsCodex {
    /// Skips the lines that are big and say nothing countable: encrypted
    /// reasoning, tool outputs, the world-state dump and the compaction
    /// replacement history (its `context_compacted` twin is counted).
    static func worthParsing(_ line: Data) -> Bool {
        !skipMarkers.contains { line.range(of: $0) != nil }
    }

    private static let skipMarkers = [
        Data("\"encrypted_content\"".utf8),
        Data("\"function_call_output\"".utf8),
        Data("\"custom_tool_call_output\"".utf8),
        Data("\"type\":\"world_state\"".utf8),
        Data("\"type\":\"compacted\"".utf8),
    ]

    static let commandTools: Set<String> = ["exec", "shell", "exec_command", "container.exec", "local_shell"]

    /// Conductor puts the person's own words after its tagged blocks in
    /// the same message — sometimes after two of them (the attachments
    /// list is another).
    static func withoutPreamble(_ text: String) -> String {
        var rest = text
        while let open = rest.range(of: "<system_instruction>"),
              let close = rest.range(of: "</system_instruction>", range: open.upperBound..<rest.endIndex) {
            rest.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func ingest(_ obj: [String: Any], sessionID: String, into entry: inout StatsScanner.FileEntry,
                              calendar: Calendar = .current) {
        guard let type = obj["type"] as? String,
              let stamp = obj["timestamp"] as? String, let t = TokenRateScanner.parseStamp(stamp) else { return }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        if entry.cwd == nil, let cwd = payload["cwd"] as? String, !cwd.isEmpty { entry.cwd = cwd }
        let key = Stats.dayKey(Date(timeIntervalSince1970: t), calendar: calendar)
        var day = entry.days[key] ?? Stats.Day()
        StatsScanner.noteSession(&day, key: key, at: t, sessionID: sessionID, into: &entry, calendar: calendar)
        defer { entry.days[key] = day }

        switch type {
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { entry.state.codexModel = model }
            entry.state.codexEffort = payload["effort"] as? String ?? "unset"

        case "event_msg":
            switch payload["type"] as? String {
            case "user_message":
                guard !withoutPreamble(payload["message"] as? String ?? "").isEmpty else { return }
                StatsScanner.closeStretch(into: &entry, current: &day, currentKey: key)
                entry.state.stretch = StatsScanner.Stretch(dayKey: key, at: t, engine: .codex)
                day.humanMessages += 1
                if let ended = entry.state.turnEndedAt {
                    day.waitingSeconds += min(StatsScanner.waitingCap, max(0, t - ended))
                    entry.state.turnEndedAt = nil
                }
                day.longestUnattended = max(day.longestUnattended, entry.state.toolsSinceHuman)
                entry.state.toolsSinceHuman = 0
            case "token_count":
                guard let usage = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] else { return }
                let cached = usage["cached_input_tokens"] as? Int ?? 0
                let input = max(0, (usage["input_tokens"] as? Int ?? 0) - cached)
                let output = usage["output_tokens"] as? Int ?? 0
                let model = entry.state.codexModel
                let effort = entry.state.codexEffort.isEmpty ? "unset" : entry.state.codexEffort
                var cost = 0.0
                var savings = 0.0
                if let p = StaticPriceTable.price(model: model) {
                    cost = (Double(input) * p.input + Double(output) * p.output + Double(cached) * p.cacheRead) / 1_000_000
                    savings = Double(cached) * max(0, p.input - p.cacheRead) / 1_000_000
                }
                day.inputTokens += input
                day.outputTokens += output
                if output > 0 { day.minuteTokens[Stats.minuteOfDay(t, calendar: calendar), default: 0] += output }
                day.usd += cost
                day.cacheReadTokens += cached
                day.cacheSavingsUSD += savings
                day.charge(model: model, engine: entry.engine, effort: effort, input: input, output: output, usd: cost,
                           cacheRead: cached, savings: savings)
                if entry.state.stretch != nil {
                    entry.state.stretch!.model = model
                    entry.state.stretch!.effort = effort
                    entry.state.stretch!.inputTokens += input
                    entry.state.stretch!.outputTokens += output
                    entry.state.stretch!.usd += cost
                    entry.state.stretch!.entries += 1
                    entry.state.stretch!.lastAt = max(entry.state.stretch!.lastAt, t)
                }
            case "patch_apply_end":
                let paths = Array((payload["changes"] as? [String: Any] ?? [:]).keys)
                day.toolCalls["apply_patch", default: 0] += 1
                entry.state.toolsSinceHuman += 1
                if entry.state.stretch != nil {
                    entry.state.stretch!.edits += paths.count
                    entry.state.stretch!.testEdits += paths.filter(StatsScanner.ActivitySignals.isTestPath).count
                    entry.state.stretch!.lastAt = max(entry.state.stretch!.lastAt, t)
                }
            case "web_search_end":
                day.toolCalls["web_search", default: 0] += 1
                entry.state.toolsSinceHuman += 1
            case "task_complete", "turn_aborted":
                if entry.state.turnEndedAt == nil { day.turns += 1 }
                entry.state.turnEndedAt = t
                if entry.state.stretch != nil {
                    entry.state.stretch!.endedInProse = true
                    entry.state.stretch!.lastAt = max(entry.state.stretch!.lastAt, t)
                }
            case "context_compacted":
                day.compactions += 1
            default:
                break
            }

        case "response_item":
            guard let kind = payload["type"] as? String, kind == "function_call" || kind == "custom_tool_call",
                  let name = payload["name"] as? String else { return }
            if entry.state.stretch != nil { entry.state.stretch!.lastAt = max(entry.state.stretch!.lastAt, t) }
            // `wait` re-polls a command that is still running: the agent
            // is busy, but it isn't another tool call.
            guard name != "wait" else { return }
            day.toolCalls[name, default: 0] += 1
            entry.state.toolsSinceHuman += 1
            guard entry.state.stretch != nil else { return }
            if commandTools.contains(name) {
                // The command text — a JS snippet for `exec`, a JSON
                // arguments string otherwise — carries the same markers
                // a Bash command does.
                let text = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
                StatsScanner.feedStretch(&entry.state.stretch!, tool: "Bash", input: ["command": text])
            }

        default:
            break
        }
    }
}
