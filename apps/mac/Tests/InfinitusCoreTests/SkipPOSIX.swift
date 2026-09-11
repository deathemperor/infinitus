import XCTest

/// Shared by the suites that shell out or assert POSIX-only file
/// semantics: a no-op everywhere POSIX exists, a skip on Windows.
func skipOffPOSIX() throws {
    #if os(Windows)
    try XCTSkipIf(true, "Team git shellouts / POSIX modes are not ported to Windows yet")
    #endif
}
