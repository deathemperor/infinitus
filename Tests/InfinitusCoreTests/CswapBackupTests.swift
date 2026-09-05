import XCTest
@testable import InfinitusCore

/// `CswapCLI.importNeedsForce` — the one judgement call in the backup
/// path, and the only place a wrong answer would offer to overwrite
/// someone's accounts unasked.
///
/// cswap has no `--json` for export/import (the engine scopes that flag
/// to list/status/switch), so the failure reason is plain English on
/// stderr and this has to read it. The bias is therefore deliberate: a
/// MISS shows the engine's message and offers nothing, so a reworded
/// error degrades to "here's what it said" rather than to a destructive
/// retry the user never asked for.
final class CswapBackupTests: XCTestCase {
    /// The messages that mean "retrying with --force is your decision".
    func testDetectsAnAlreadyExistsRefusal() {
        for message in [
            "account 1 already exists — pass --force to replace it",
            "Account already exists",
            "--force is required to replace existing accounts",
            "ALREADY EXISTS",
        ] {
            XCTAssertTrue(CswapCLI.importNeedsForce(message),
                          "should offer --force for: \(message)")
        }
    }

    /// Everything else must NOT escalate. These are real failures from
    /// this engine (verified 2026-09-04) plus the empty case — none of
    /// them is fixed by overwriting accounts, and offering to would be
    /// destructive for no reason.
    func testDoesNotEscalateOtherFailures() {
        for message in [
            "import file not found: C:\\tmp\\nope.json",
            "export file is not valid JSON: Expecting value: line 1 column 1 (char 0)",
            "no accounts to export — run cswap --add-account first",
            "cswap import exited 1",
            "",
        ] {
            XCTAssertFalse(CswapCLI.importNeedsForce(message),
                           "must not offer to overwrite for: \(message)")
        }
    }
}
