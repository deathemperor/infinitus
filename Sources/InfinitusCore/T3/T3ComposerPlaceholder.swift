import Foundation

/// The composer's placeholder rule (`ChatComposer.tsx:5432-5450`), which is a
/// seven-branch ladder over the thread's state, not one constant.
///
/// The Mac reference (`tools/t3ref/refs/mac-*.png`) shows the sixth branch —
/// `DISCONNECTED_COMPOSER_PLACEHOLDER` (`composerPlaceholder.ts:1-2`), reached
/// only through `phase === "disconnected"`, which `derivePhase`
/// (`session-logic.ts:1673-1685`) returns for a thread with no session, or one
/// stopped, interrupted or errored. The reference thread was recreated by hand
/// in T3 Code and never ran, so its composer is in that state; a live thread's
/// is not. The string is reference STATE, like the hover-revealed timestamp
/// the harness already documents — not a constant to hard-code.
public enum T3ComposerPlaceholder {
    /// `SessionPhase` (`types.ts:24`) as this port can observe it: B's
    /// counterpart of "no session" is the timeline store having lost the
    /// record for this pid (`T3TimelineStore.gone`).
    public enum Phase: String, Sendable, Equatable {
        case disconnected, connecting, ready, running
    }

    /// `composerPlaceholder.ts:1-2`.
    public static let disconnected = "Ask for changes, send follow-ups, or attach images"

    /// The ladder's tail. Upstream's is `:5449`, which promises `@tag
    /// files/folders, $use skills, or / for commands` — `$` skills have no
    /// producer on B (`T3ComposerTrigger`'s header carries the reason), so
    /// that sentence would promise a key that does nothing. `:4998`'s
    /// "Ask anything..." is the SAME composer's own shorter form of it (the
    /// collapsed prompt row), so the port takes an upstream string rather
    /// than editing one.
    public static let fallback = "Ask anything..."

    /// `:5433-5449` in upstream's own order — the first branch that matches
    /// wins.
    ///
    /// - Parameters:
    ///   - approval: the pending approval's `detail` when the composer is in
    ///     `isComposerApprovalState`, `nil` when it is not; an empty detail
    ///     falls to upstream's own sentence (`activePendingApproval?.detail ??`).
    ///   - question: a pending question and whether it takes only a choice
    ///     (`isChoiceOnlyPendingQuestion`).
    ///   - planFollowUp: `showPlanFollowUpPrompt && activeProposedPlan`.
    ///   - projectSelectionRequired: a draft with no project picked yet.
    ///   - noProviderAvailable: no engine can answer.
    public static func text(phase: Phase,
                            approval: (pending: Bool, detail: String?),
                            question: (pending: Bool, choiceOnly: Bool),
                            planFollowUp: Bool,
                            projectSelectionRequired: Bool,
                            noProviderAvailable: Bool) -> String {
        if approval.pending {
            if let detail = approval.detail, !detail.isEmpty { return detail }
            return "Resolve this approval request to continue"
        }
        if question.pending {
            return question.choiceOnly
                ? "Choose an option above"
                : "Type your own answer, or leave this blank to use the selected option"
        }
        if planFollowUp { return "Add feedback to refine the plan, or leave this blank to implement it" }
        if projectSelectionRequired { return "Choose a project above to start a thread" }
        if noProviderAvailable { return "Enable a provider in Settings to send a message" }
        if phase == .disconnected { return disconnected }
        return fallback
    }
}
