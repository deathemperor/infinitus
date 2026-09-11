import SwiftUI
import InfinitusCore

/// A parked AskUserQuestion with every question on it (#151 follow-up):
/// one pick per question — several on a multi-select — and one Send that
/// answers them all (`SessionInput.Request.Kind.answers`). Shared by the
/// Mac's chat window and the phone's feed screen; the browser page draws
/// its own. Give it an `.id` per prompt so the picks reset with it.
public struct QuestionsPrompt: View {
    public let questions: [PendingRequest.Question]
    public let sending: Bool
    /// Receives `SessionInput.Answers.encode`'s text.
    public let submit: (String) -> Void
    @State private var picks: [Int: Set<Int>] = [:]

    public init(questions: [PendingRequest.Question], sending: Bool, submit: @escaping (String) -> Void) {
        self.questions = questions
        self.sending = sending
        self.submit = submit
    }

    private var complete: Bool { questions.indices.allSatisfy { !(picks[$0] ?? []).isEmpty } }

    private var answers: [String: String] {
        var out: [String: String] = [:]
        for (i, q) in questions.enumerated() {
            out[q.question] = (picks[i] ?? []).sorted().map { q.options[$0] }
                .joined(separator: SessionInput.Answers.separator)
        }
        return out
    }

    private func toggle(_ i: Int, _ j: Int, multi: Bool) {
        var set = picks[i] ?? []
        if set.contains(j) { set.remove(j) } else if multi { set.insert(j) } else { set = [j] }
        picks[i] = set
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { i, q in
                VStack(alignment: .leading, spacing: 6) {
                    if !q.header.isEmpty {
                        Text(q.header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Label(q.question, systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                    ForEach(Array(q.options.enumerated()), id: \.offset) { j, option in
                        let on = picks[i]?.contains(j) == true
                        Button { toggle(i, j, multi: q.multiSelect) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: q.multiSelect ? (on ? "checkmark.square.fill" : "square")
                                                                : (on ? "checkmark.circle.fill" : "circle"))
                                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                                Text(option).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Option \(j + 1) of \(q.options.count): \(option)")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 10) {
                Button(complete ? (questions.count == 1 ? "Send answer" : "Send \(questions.count) answers")
                                : "Answer every question") {
                    submit(SessionInput.Answers.encode(answers))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!complete || sending)
                if sending { ProgressView().controlSize(.small) }
            }
        }
    }
}
