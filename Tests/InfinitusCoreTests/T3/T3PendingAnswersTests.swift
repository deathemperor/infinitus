import XCTest
@testable import InfinitusCore

/// The answer side of a parked `AskUserQuestion` (#422): one encoder for the
/// Mac workspace panel and the phone card, checked against its decoder
/// (`OwnedWire.decision(answers:pending:)`) with a round trip below.
final class T3PendingAnswersTests: XCTestCase {

    // MARK: - parse

    private func questionJSON(id: String? = "q1", question: String? = "Pick one",
                              header: String = "Header", multiSelect: JSONValue? = nil,
                              allowCustomAnswer: JSONValue? = nil,
                              options: [JSONValue]? = [.object(["label": .string("A"), "description": .string("")])]) -> JSONValue {
        var o: [String: JSONValue] = ["header": .string(header)]
        if let id { o["id"] = .string(id) }
        if let question { o["question"] = .string(question) }
        if let multiSelect { o["multiSelect"] = multiSelect }
        if let allowCustomAnswer { o["allowCustomAnswer"] = allowCustomAnswer }
        if let options { o["options"] = .array(options) }
        return .object(o)
    }

    func testParseDropsAnEntryWithNoQuestionText() {
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(question: nil)]), [])
    }

    func testParseDropsAnEntryWithEmptyOrMissingOptions() {
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(options: [])]), [])
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(options: nil)]), [])
    }

    func testParseAllowCustomAnswerDefaultsToTrue() {
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(allowCustomAnswer: nil)]).first?.allowCustomAnswer, true)
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(allowCustomAnswer: .bool(false))]).first?.allowCustomAnswer, false)
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(allowCustomAnswer: .bool(true))]).first?.allowCustomAnswer, true)
    }

    func testParseMultiSelectDefaultsToFalse() {
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(multiSelect: nil)]).first?.multiSelect, false)
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(multiSelect: .bool(true))]).first?.multiSelect, true)
    }

    func testParseIdFallsBackToTheQuestionText() {
        XCTAssertEqual(T3PendingAnswers.parse([questionJSON(id: nil, question: "Which colour?")]).first?.id, "Which colour?")
    }

    // MARK: - typedAnswer / separatorInMultiSelectText

    private func question(multiSelect: Bool = false, allowCustomAnswer: Bool = true,
                          options: [String] = ["Red", "Blue"]) -> T3PendingAnswers.Question {
        T3PendingAnswers.Question(id: "q", question: "Which colour?", header: "", multiSelect: multiSelect,
                                  allowCustomAnswer: allowCustomAnswer,
                                  options: options.map { T3PendingAnswers.Option(label: $0, description: "") })
    }

    func testTypedAnswerIsTrimmed() {
        let q = question()
        XCTAssertEqual(T3PendingAnswers.typedAnswer(q, custom: ["q": "  teal  "]), "teal")
    }

    func testTypedAnswerIsNilWhenBlank() {
        let q = question()
        XCTAssertNil(T3PendingAnswers.typedAnswer(q, custom: ["q": "   "]))
        XCTAssertNil(T3PendingAnswers.typedAnswer(q, custom: [:]))
    }

    func testTypedAnswerIsNilWhenTheQuestionWithdrewTheField() {
        let q = question(allowCustomAnswer: false)
        XCTAssertNil(T3PendingAnswers.typedAnswer(q, custom: ["q": "teal"]))
    }

    func testTypedAnswerIsNilOnAMultiSelectCarryingTheSeparator() {
        let q = question(multiSelect: true)
        XCTAssertNil(T3PendingAnswers.typedAnswer(q, custom: ["q": "Teal, Grey"]))
    }

    func testTypedAnswerOnASingleSelectCanCarryTheSeparatorText() {
        let q = question(multiSelect: false)
        XCTAssertEqual(T3PendingAnswers.typedAnswer(q, custom: ["q": "Teal, Grey"]), "Teal, Grey")
    }

    func testSeparatorInMultiSelectTextOnlyFlagsMultiSelectAllowedTextWithTheSeparator() {
        XCTAssertTrue(T3PendingAnswers.separatorInMultiSelectText(question(multiSelect: true), custom: ["q": "Teal, Grey"]))
        XCTAssertFalse(T3PendingAnswers.separatorInMultiSelectText(question(multiSelect: true), custom: ["q": "Teal"]))
        XCTAssertFalse(T3PendingAnswers.separatorInMultiSelectText(question(multiSelect: true, allowCustomAnswer: false), custom: ["q": "Teal, Grey"]))
        XCTAssertFalse(T3PendingAnswers.separatorInMultiSelectText(question(multiSelect: false), custom: ["q": "Teal, Grey"]),
                       "a single-select's text never needs the split rule")
    }

    // MARK: - encode

    func testEncodeIsNilWhileAnyQuestionIsUnanswered() {
        let colour = question(options: ["Red", "Blue"])
        let sizes = T3PendingAnswers.Question(id: "s", question: "Which size?", header: "", multiSelect: false,
                                              options: [.init(label: "S", description: ""), .init(label: "M", description: "")])
        XCTAssertNil(T3PendingAnswers.encode([colour, sizes], picks: ["q": ["Red"]], custom: [:]), "the size question went unanswered")
    }

    func testEncodeTypedAnswerReplacesPicks() {
        let q = question()
        let out = T3PendingAnswers.encode([q], picks: ["q": ["Red"]], custom: ["q": "Teal"])
        XCTAssertEqual(out.flatMap(SessionInput.Answers.decode), ["Which colour?": "Teal"])
    }

    func testEncodeMultiSelectLabelsAreInOptionOrderRegardlessOfPickOrder() {
        let q = question(multiSelect: true, options: ["Red", "Green", "Blue"])
        let out = T3PendingAnswers.encode([q], picks: ["q": ["Blue", "Red"]], custom: [:])
        XCTAssertEqual(out.flatMap(SessionInput.Answers.decode), ["Which colour?": "Red, Blue"])
    }

    func testEncodeIsKeyedByTheQuestionText() {
        let q = question()
        let out = T3PendingAnswers.encode([q], picks: ["q": ["Red"]], custom: [:])
        XCTAssertEqual(out.flatMap(SessionInput.Answers.decode)?.keys.first, "Which colour?")
    }

    func testEncodeIgnoresAPickLabelNotAmongTheOptions() {
        let q = question(multiSelect: true, options: ["Red", "Blue"])
        let out = T3PendingAnswers.encode([q], picks: ["q": ["Red", "Purple"]], custom: [:])
        XCTAssertEqual(out.flatMap(SessionInput.Answers.decode), ["Which colour?": "Red"])
        XCTAssertNil(T3PendingAnswers.encode([q], picks: ["q": ["Purple"]], custom: [:]),
                    "an unrecognised pick alone answers nothing")
    }

    // MARK: - round trip against the decoder

    private func pending(_ questions: [T3PendingAnswers.Question]) -> PendingRequest {
        PendingRequest(requestId: "r", toolName: "AskUserQuestion", toolUseId: nil, description: nil,
                       inputJSON: "{}", suggestionsJSON: nil,
                       questions: questions.map {
                           PendingRequest.Question(question: $0.question, header: $0.header,
                                                   options: $0.options.map(\.label), multiSelect: $0.multiSelect)
                       }, receivedAt: Date())
    }

    func testRoundTripSingleSelectPick() throws {
        let q = question(options: ["Red", "Blue"])
        let text = try XCTUnwrap(T3PendingAnswers.encode([q], picks: ["q": ["Blue"]], custom: [:]))
        XCTAssertEqual(OwnedWire.decision(answers: text, pending: pending([q])), .answers(["Which colour?": "Blue"]))
    }

    func testRoundTripMultiSelectTwoPicks() throws {
        let q = question(multiSelect: true, options: ["Red", "Green", "Blue"])
        let text = try XCTUnwrap(T3PendingAnswers.encode([q], picks: ["q": ["Blue", "Red"]], custom: [:]))
        XCTAssertEqual(OwnedWire.decision(answers: text, pending: pending([q])), .answers(["Which colour?": "Red, Blue"]))
    }

    func testRoundTripFreeTextOnASingleSelect() throws {
        let q = question(options: ["Red", "Blue"])
        let text = try XCTUnwrap(T3PendingAnswers.encode([q], picks: [:], custom: ["q": "Teal, please"]))
        XCTAssertEqual(OwnedWire.decision(answers: text, pending: pending([q])), .answers(["Which colour?": "Teal, please"]))
    }

    func testRoundTripFreeTextOnAMultiSelectWithoutSeparator() throws {
        let q = question(multiSelect: true, options: ["Red", "Blue"])
        let text = try XCTUnwrap(T3PendingAnswers.encode([q], picks: [:], custom: ["q": "huge"]))
        XCTAssertEqual(OwnedWire.decision(answers: text, pending: pending([q])), .answers(["Which colour?": "huge"]))
    }

    // MARK: - menuKey

    func testMenuKeyFirstPickIsOneBased() {
        let q = question(options: ["Red", "Blue"])
        XCTAssertEqual(T3PendingAnswers.menuKey([q], picks: ["q": ["Blue"]]), "2")
    }

    func testMenuKeyIsNilWhenNothingIsPicked() {
        let q = question(options: ["Red", "Blue"])
        XCTAssertNil(T3PendingAnswers.menuKey([q], picks: [:]))
    }

    func testMenuKeyIsNilPastTheNinthOption() {
        let options = (1...10).map { "Option \($0)" }
        let q = question(options: options)
        XCTAssertNil(T3PendingAnswers.menuKey([q], picks: ["q": ["Option 10"]]))
        XCTAssertEqual(T3PendingAnswers.menuKey([q], picks: ["q": ["Option 9"]]), "9")
    }

    func testMenuKeyUsesTheFirstQuestionOnly() {
        let first = question(options: ["Red", "Blue"])
        let second = T3PendingAnswers.Question(id: "s", question: "Which size?", header: "", multiSelect: false,
                                               options: [.init(label: "S", description: "")])
        XCTAssertNil(T3PendingAnswers.menuKey([first, second], picks: ["s": ["S"]]), "only the first question's picks count")
    }
}
