import XCTest
import InfinitusCore

/// `infinitus-win export` / `import` — the guards, not the engine.
///
/// The round trip itself was verified live on 2026-09-04 (a throwaway
/// API-key slot exported, the slot removed, then restored from the file
/// with its number and email intact). What is pinned here is everything
/// that must hold WITHOUT an engine or an account, because those are the
/// paths a user hits by accident:
///
///  - a destructive restore cannot happen from one mistyped flag
///  - an export never silently overwrites an existing backup
///  - a missing or malformed file fails before anything is touched
final class BackupTests: XCTestCase {
    /// `--force` without `--yes` must refuse and change nothing. Exit 2
    /// (usage), not 1, so a script can tell "you must confirm" from "the
    /// engine said no".
    func testForceImportRefusesWithoutConfirmation() throws {
        try DaemonHarness.scratch { dir in
            let file = dir.appendingPathComponent("backup.json")
            try #"{"version":1,"accounts":[]}"#.write(to: file, atomically: true, encoding: .utf8)
            let (lines, errors, status) = try DaemonHarness.run(
                ["import", file.path, "--force"])
            XCTAssertEqual(status, 2, "a destructive restore must not proceed unconfirmed")
            let text = (lines + errors).joined(separator: "\n")
            XCTAssertTrue(text.contains("--yes"), "it must say how to confirm: \(text)")
            XCTAssertTrue(text.lowercased().contains("no undo"), text)
        }
    }

    /// An import path that isn't there fails before any warning about
    /// overwriting — the likeliest mistake is a wrong path, not intent.
    func testImportRejectsMissingFile() throws {
        try DaemonHarness.scratch { dir in
            let missing = dir.appendingPathComponent("nope.json")
            let (lines, errors, status) = try DaemonHarness.run(["import", missing.path])
            XCTAssertEqual(status, 2)
            XCTAssertTrue((lines + errors).joined().contains("not found"),
                          (lines + errors).joined())
        }
    }

    /// An export must never clobber an existing file: the old one may be
    /// somebody's only copy of a credential.
    func testExportRefusesToOverwrite() throws {
        try DaemonHarness.scratch { dir in
            let file = dir.appendingPathComponent("existing.json")
            try "PRECIOUS".write(to: file, atomically: true, encoding: .utf8)
            let (lines, errors, status) = try DaemonHarness.run(["export", file.path])
            XCTAssertEqual(status, 2)
            XCTAssertTrue((lines + errors).joined().contains("already exists"),
                          (lines + errors).joined())
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "PRECIOUS",
                           "the existing backup must be untouched")
        }
    }

    /// Without an engine both verbs fail cleanly rather than crashing or
    /// claiming success.
    func testBothVerbsFailWithoutAnEngine() throws {
        try DaemonHarness.scratch { dir in
            let out = dir.appendingPathComponent("out.json")
            let (_, errors, status) = try DaemonHarness.run(
                ["export", out.path], environment: ["INFINITUS_CSWAP": ""])
            XCTAssertEqual(status, 1)
            XCTAssertTrue(errors.joined().contains("no swap engine"), errors.joined())
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path),
                           "a failed export must not leave a file behind")

            let file = dir.appendingPathComponent("backup.json")
            try #"{"version":1,"accounts":[]}"#.write(to: file, atomically: true, encoding: .utf8)
            let (_, importErrors, importStatus) = try DaemonHarness.run(
                ["import", file.path], environment: ["INFINITUS_CSWAP": ""])
            XCTAssertEqual(importStatus, 1)
            XCTAssertTrue(importErrors.joined().contains("no swap engine"), importErrors.joined())
        }
    }

    /// A second path is a mistake worth catching: `export a.json b.json`
    /// would otherwise silently ignore one of them.
    func testExportRejectsTwoPaths() throws {
        try DaemonHarness.scratch { dir in
            let (_, errors, status) = try DaemonHarness.run(
                ["export", dir.appendingPathComponent("a.json").path,
                 dir.appendingPathComponent("b.json").path])
            XCTAssertNotEqual(status, 0)
            XCTAssertTrue(errors.joined().contains("one path"), errors.joined())
        }
    }
}
