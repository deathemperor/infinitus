import Foundation

/// The answer side of a parked `AskUserQuestion`: the questions as the
/// activity payload carries them, and the wire text a client sends back.
/// One encoder for the Mac workspace and the phone — the decoder is
/// `OwnedWire.decision(answers:pending:)`.
public enum T3PendingAnswers {
    public struct Option: Equatable, Identifiable, Sendable {
        public let label: String
        public let description: String
        public var id: String { label }
        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }
    public struct Question: Equatable, Identifiable, Sendable {
        /// Upstream's `question.id`; option rows key off it.
        public let id: String
        /// The `answers` JSON KEY — `OwnedWire.decision(answers:pending:)`
        /// looks each answer up by the question's text, never `id`.
        public let question: String
        public let header: String
        public let multiSelect: Bool
        /// `allowCustomAnswer: Schema.optional(Schema.Boolean)`
        /// (providerRuntime.ts:539): absent = allowed, only an explicit
        /// `false` withdraws the free-text field (pendingUserInput.ts:48).
        public let allowCustomAnswer: Bool
        public let options: [Option]
        public init(id: String, question: String, header: String, multiSelect: Bool,
                    allowCustomAnswer: Bool = true, options: [Option]) {
            self.id = id
            self.question = question
            self.header = header
            self.multiSelect = multiSelect
            self.allowCustomAnswer = allowCustomAnswer
            self.options = options
        }
    }

    /// The activity payload's `questions` array → questions. Drops an entry
    /// with no `question` text or no options, the way the phone's
    /// `T3Pending.derive` does (ios/InfinitusMobile/T3/T3Pending.swift:69-81).
    public static func parse(_ questions: [JSONValue]) -> [Question] {
        questions.compactMap { q in
            guard let o = q.objectValue, let text = o["question"]?.stringValue else { return nil }
            let options = (o["options"]?.arrayValue ?? []).compactMap { opt -> Option? in
                guard let d = opt.objectValue, let label = d["label"]?.stringValue else { return nil }
                return Option(label: label, description: d["description"]?.stringValue ?? "")
            }
            guard !options.isEmpty else { return nil }
            return Question(id: o["id"]?.stringValue ?? text, question: text,
                            header: o["header"]?.stringValue ?? "",
                            multiSelect: o["multiSelect"].map { $0 == .bool(true) } ?? false,
                            allowCustomAnswer: o["allowCustomAnswer"] != .bool(false),
                            options: options)
        }
    }

    /// `normalizeDraftAnswer` (pendingUserInput.ts:24-30): the question's
    /// deliverable typed answer, trimmed (whitespacesAndNewlines); nil when
    /// the question withdrew the field, the field is blank, or the text is
    /// a multi-select's carrying `SessionInput.Answers.separator` (the
    /// decoder splits a multi-select answer on it and needs every part to
    /// be an option, so that text could only be rejected).
    public static func typedAnswer(_ q: Question, custom: [String: String]) -> String? {
        guard q.allowCustomAnswer else { return nil }
        let trimmed = (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return q.multiSelect && trimmed.contains(SessionInput.Answers.separator) ? nil : trimmed
    }

    /// Text in a multi-select's field that `typedAnswer` has to drop — so
    /// a card can say why instead of leaving Submit dead.
    public static func separatorInMultiSelectText(_ q: Question, custom: [String: String]) -> Bool {
        guard q.allowCustomAnswer, q.multiSelect else { return false }
        return (custom[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .contains(SessionInput.Answers.separator)
    }

    /// `buildPendingUserInputAnswers` (pendingUserInput.ts:110-125): every
    /// question answered — a typed answer stands in for the picks
    /// (`resolvePendingUserInputAnswer`), otherwise the picked labels in
    /// OPTION order joined by `SessionInput.Answers.separator` — keyed by
    /// question text and encoded with `SessionInput.Answers.encode`.
    /// nil until every question has an answer.
    public static func encode(_ questions: [Question], picks: [String: Set<String>], custom: [String: String]) -> String? {
        var out: [String: String] = [:]
        for q in questions {
            if let typed = typedAnswer(q, custom: custom) {
                // `resolvePendingUserInputAnswer` (`pendingUserInput.ts:42-68`)
                // returns the custom answer over the selection, and
                // `OwnedWire.decision(answers:pending:)` takes one non-option
                // string per question as Claude Code's "Other"
                // (OwnedWire.swift:283-289).
                out[q.question] = typed
                continue
            }
            let chosen = q.options.map(\.label).filter { picks[q.id]?.contains($0) == true }
            guard !chosen.isEmpty else { return nil }
            out[q.question] = chosen.joined(separator: SessionInput.Answers.separator)
        }
        return SessionInput.Answers.encode(out)
    }

    /// A terminal-hosted session's menu key: the first question's single
    /// pick as its 1-based option number, nil when unpicked or past 9
    /// (`OwnedWire.decision(forKey:)`, `SessionInput.allowedKeys`).
    public static func menuKey(_ questions: [Question], picks: [String: Set<String>]) -> String? {
        guard let q = questions.first, let label = picks[q.id]?.first,
              let i = q.options.firstIndex(where: { $0.label == label }), i < 9 else { return nil }
        return String(i + 1)
    }
}
