import XCTest
import InfinitusCore

/// The notification text comes from cswap's event stream — hostile input
/// must stay inside the AppleScript string literal.
final class NotifierTests: XCTestCase {
    func testQuoteIsEscaped() {
        XCTAssertEqual(AppleScriptEscaping.literal(#"a "b" c"#), #"a \"b\" c"#)
    }

    func testBackslashQuoteCannotReopenLiteral() {
        // Without backslash-first escaping, `\"` became `\\"` — a literal
        // backslash followed by a string terminator.
        XCTAssertEqual(AppleScriptEscaping.literal(#"x\" & (do shell script "id")"#),
                       #"x\\\" & (do shell script \"id\")"#)
    }

    func testNewlinesFlattened() {
        XCTAssertEqual(AppleScriptEscaping.literal("a\nb"), "a b")
    }
}
