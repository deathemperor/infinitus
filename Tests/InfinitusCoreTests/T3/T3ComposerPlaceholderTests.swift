import XCTest
@testable import InfinitusCore

/// `ChatComposer.tsx:5432-5450`'s placeholder ladder — every branch, and the
/// order between them (the ladder is `?:`-chained, so an earlier branch must
/// win over a later one that also matches).
final class T3ComposerPlaceholderTests: XCTestCase {
    private func text(phase: T3ComposerPlaceholder.Phase = .ready,
                      approval: (pending: Bool, detail: String?) = (false, nil),
                      question: (pending: Bool, choiceOnly: Bool) = (false, false),
                      planFollowUp: Bool = false,
                      projectSelectionRequired: Bool = false,
                      noProviderAvailable: Bool = false) -> String {
        T3ComposerPlaceholder.text(phase: phase, approval: approval, question: question,
                                   planFollowUp: planFollowUp,
                                   projectSelectionRequired: projectSelectionRequired,
                                   noProviderAvailable: noProviderAvailable)
    }

    func testLiveThreadGetsTheFallback() {
        XCTAssertEqual(text(phase: .ready), T3ComposerPlaceholder.fallback)
        XCTAssertEqual(text(phase: .running), T3ComposerPlaceholder.fallback)
        XCTAssertEqual(text(phase: .connecting), T3ComposerPlaceholder.fallback)
    }

    /// The branch the Mac reference is in: its thread was recreated by hand
    /// and never ran, so `derivePhase` answers `disconnected`.
    func testDisconnectedThreadGetsTheReferenceString() {
        XCTAssertEqual(text(phase: .disconnected),
                       "Ask for changes, send follow-ups, or attach images")
    }

    func testApprovalUsesItsDetail() {
        XCTAssertEqual(text(approval: (true, "Run `rm -rf build`?")), "Run `rm -rf build`?")
    }

    func testApprovalWithoutDetailFallsToUpstreamsSentence() {
        XCTAssertEqual(text(approval: (true, nil)), "Resolve this approval request to continue")
        XCTAssertEqual(text(approval: (true, "")), "Resolve this approval request to continue")
    }

    func testChoiceOnlyQuestionAndFreeTextQuestionDiffer() {
        XCTAssertEqual(text(question: (true, true)), "Choose an option above")
        XCTAssertEqual(text(question: (true, false)),
                       "Type your own answer, or leave this blank to use the selected option")
    }

    func testPlanFollowUpProjectAndProviderBranches() {
        XCTAssertEqual(text(planFollowUp: true),
                       "Add feedback to refine the plan, or leave this blank to implement it")
        XCTAssertEqual(text(projectSelectionRequired: true), "Choose a project above to start a thread")
        XCTAssertEqual(text(noProviderAvailable: true), "Enable a provider in Settings to send a message")
    }

    /// The ladder's order: an approval outranks a question, a question
    /// outranks the plan prompt, and `disconnected` is the LAST branch before
    /// the fallback — so every state above it wins even on a dead session.
    func testEarlierBranchesWinOverLaterOnes() {
        XCTAssertEqual(text(approval: (true, "detail"), question: (true, true)), "detail")
        XCTAssertEqual(text(question: (true, true), planFollowUp: true), "Choose an option above")
        XCTAssertEqual(text(planFollowUp: true, projectSelectionRequired: true),
                       "Add feedback to refine the plan, or leave this blank to implement it")
        XCTAssertEqual(text(projectSelectionRequired: true, noProviderAvailable: true),
                       "Choose a project above to start a thread")
        XCTAssertEqual(text(phase: .disconnected, noProviderAvailable: true),
                       "Enable a provider in Settings to send a message")
    }

    /// The tail is `:4998`'s "Ask anything...", the same composer's own
    /// shorter form — not `:5449`'s, which promises `$use skills` B has no
    /// producer for.
    func testFallbackIsUpstreamsShorterForm() {
        XCTAssertEqual(T3ComposerPlaceholder.fallback, "Ask anything...")
    }
}
