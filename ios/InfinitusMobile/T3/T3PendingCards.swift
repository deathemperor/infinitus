import SwiftUI
import InfinitusCore
import InfinitusUI

/// T3's `PendingApprovalCard`: an opaque card-alt panel, the tool as
/// the title, the rendered input under it, three pills — Allow once
/// (primary), Allow session (subtle, the Mac's #79 rule), Decline
/// (danger).
struct T3ApprovalCard: View {
    let approval: T3Pending.Approval
    let sending: Bool
    let allowOnce: () -> Void
    let allowSession: () -> Void
    let decline: () -> Void
    @Environment(\.t3) private var t3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            T3CardEyebrow(text: "Approval needed")
            Text(approval.toolName).font(T3Font.mobile(.lg, .bold)).foregroundStyle(t3.mobile.foreground.color)
            if !approval.detail.isEmpty {
                Text(approval.detail).font(T3Font.mobile(.sm)).lineLimit(6)
                    .foregroundStyle(t3.mobile.foregroundSecondary.color)
                    .textSelection(.enabled)
            }
            HStack(spacing: 10) {
                pill("Allow once", fill: t3.mobile.primary, text: t3.mobile.primaryForeground, action: allowOnce)
                pill("Allow session", fill: t3.mobile.subtleStrong, text: t3.mobile.foreground, action: allowSession)
                    .accessibilityHint("Allows \(approval.rule.label) for this session")
                pill("Decline", fill: t3.mobile.danger, text: t3.mobile.dangerForeground, action: decline)
            }
            .disabled(sending)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t3.mobile.cardAlt.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(t3.mobile.border.color, lineWidth: 1))
    }

    private func pill(_ label: String, fill: T3RGBA, text: T3RGBA, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(T3Font.mobile(.sm, .bold)).foregroundStyle(text.color).lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(fill.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// T3's `PendingUserInputCard`: collapsed, a pill saying how many
/// questions wait; expanded, every question with its options as
/// selectable rows, a custom-answer field, and one Submit for all
/// (#330's answers).
struct T3UserInputCard: View {
    let input: T3Pending.UserInput
    let sending: Bool
    let submit: (T3Pending.Submission) -> Void
    @State private var collapsed = false
    @State private var picks: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @Environment(\.t3) private var t3

    /// A terminal session answers its first question by menu key: one
    /// pick, no typing (the feed's older path).
    private var questions: [T3Pending.Question] { input.owned ? input.questions : Array(input.questions.prefix(1)) }

    private var submission: T3Pending.Submission? {
        if input.owned {
            return T3Pending.encodeAnswers(questions, picks: picks, custom: custom).map { .answers($0) }
        }
        guard let q = questions.first, let label = picks[q.id]?.first,
              let i = q.options.firstIndex(where: { $0.label == label }) else { return nil }
        return .key(String(i + 1))
    }

    var body: some View {
        Group {
            if collapsed { pill } else { card }
        }
        .animation(.easeOut(duration: 0.22), value: collapsed)
        .onChange(of: input.requestId) { _, _ in picks = [:]; custom = [:]; collapsed = false }
    }

    private var pill: some View {
        Button { collapsed = false } label: {
            HStack(spacing: 8) {
                T3CardEyebrow(text: "User input needed")
                Text("\(questions.count) question\(questions.count == 1 ? "" : "s")")
                    .font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundMuted.color)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t3.mobile.iconMuted.color).frame(width: 36, height: 36)
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
            .frame(minHeight: 40)
            .background(t3.mobile.cardAlt.color, in: Capsule())
            .overlay(Capsule().stroke(t3.mobile.border.color, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    T3CardEyebrow(text: "User input needed")
                    Text("Fill in the pending answers").font(T3Font.mobile(.lg, .bold))
                        .foregroundStyle(t3.mobile.foreground.color)
                }
                Spacer(minLength: 0)
                Button { collapsed = true } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t3.mobile.icon.color)
                        .frame(width: 32, height: 32)
                        .background(t3.mobile.subtleStrong.color, in: Circle())
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(questions) { question in questionBlock(question) }
                }
            }
            .frame(maxHeight: 400)
            Button {
                if let submission { submit(submission) }
            } label: {
                Text(input.owned ? "Submit answers" : "Send answer").font(T3Font.mobile(.sm, .bold))
                    .foregroundStyle(submission == nil ? t3.mobile.foregroundMuted.color : t3.mobile.primaryForeground.color)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(submission == nil ? t3.mobile.subtleStrong.color : t3.mobile.primary.color,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(submission == nil || sending)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t3.mobile.cardAlt.color, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(t3.mobile.border.color, lineWidth: 1))
    }

    private func questionBlock(_ question: T3Pending.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !question.header.isEmpty {
                Text(question.header.uppercased()).font(T3Font.mobile(.xs, .bold)).tracking(1)
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
            }
            Text(question.question).font(T3Font.mobile(.base)).foregroundStyle(t3.mobile.foreground.color)
            ForEach(question.options) { option in
                let on = picks[question.id]?.contains(option.label) == true
                Button {
                    var set = picks[question.id] ?? []
                    if on { set.remove(option.label) }
                    else if question.multiSelect, input.owned { set.insert(option.label) }
                    else { set = [option.label] }
                    picks[question.id] = set
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label).font(T3Font.mobile(.sm, .bold))
                            .foregroundStyle(on ? t3.mobile.foreground.color : t3.mobile.foregroundSecondary.color)
                        if !option.description.isEmpty, option.description != option.label {
                            Text(option.description).font(T3Font.mobile(.sm)).foregroundStyle(t3.mobile.foregroundMuted.color)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(minHeight: 48)
                    .background(on ? t3.mobile.primary.color.opacity(0.1) : t3.mobile.input.color,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(on ? t3.mobile.primary.color : t3.mobile.border.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if input.owned {
                customField(question)
            }
        }
    }

    private func customField(_ question: T3Pending.Question) -> some View {
            TextField("Or type a custom answer", text: Binding(
                get: { custom[question.id] ?? "" }, set: { custom[question.id] = $0 }), axis: .vertical)
                .font(T3Font.mobile(.base)).foregroundStyle(t3.mobile.foreground.color)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(minHeight: 54)
                .background(t3.mobile.input.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(t3.mobile.inputBorder.color, lineWidth: 1))
    }
}

/// The cards' small-caps eyebrow: `text-2xs font-t3-bold uppercase tracking-[1.1px]`.
struct T3CardEyebrow: View {
    let text: String
    @Environment(\.t3) private var t3
    var body: some View {
        Text(text.uppercased()).font(T3Font.mobile(.xxs, .bold)).tracking(1.1)
            .foregroundStyle(t3.mobile.foregroundSecondary.color)
    }
}
