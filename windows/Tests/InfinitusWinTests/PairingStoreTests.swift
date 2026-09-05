import XCTest
import InfinitusCore

/// W5: the pairing token store, exercised through `infinitus-win pair`
/// with `%APPDATA%` pointed at a scratch dir — the real file, not a mock.
final class PairingStoreTests: XCTestCase {
    /// `--token-file` imports (normalizing paste damage), stores, and the
    /// pair URL carries exactly that token.
    func testPairImportsNormalizesAndStores() throws {
        try DaemonHarness.scratch { appData in
            let tokenFile = DaemonHarness.fixtures.appendingPathComponent("token-damaged.txt")
            let (lines, error, status) = try DaemonHarness.run(
                ["pair", "--token-file", tokenFile.path],
                environment: ["APPDATA": appData.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let pairing = try XCTUnwrap(MirrorPairing.parsePairURL(try XCTUnwrap(lines.first)))
            XCTAssertEqual(pairing.token, "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
            XCTAssertFalse(pairing.endpoints.isEmpty, "the URL carries at least one route")
            XCTAssertEqual(try self.storedToken(appData), pairing.token,
                           "the imported token landed in the store")
        }
    }

    /// `pair --show` reads back what a previous run stored — the token
    /// file is reused, never regenerated behind the user's back.
    func testPairShowReusesTheStoredToken() throws {
        try DaemonHarness.scratch { appData in
            let tokenFile = DaemonHarness.fixtures.appendingPathComponent("token-damaged.txt")
            _ = try DaemonHarness.run(["pair", "--token-file", tokenFile.path],
                                      environment: ["APPDATA": appData.path])
            let (lines, error, status) = try DaemonHarness.run(
                ["pair", "--show"], environment: ["APPDATA": appData.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            XCTAssertEqual(lines, ["ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"])
        }
    }

    /// `--rotate` replaces the stored token with a fresh 24×base32 one
    /// (MirrorPairing's format: no 0/O, no 1/l).
    func testPairRotateWritesAFreshToken() throws {
        try DaemonHarness.scratch { appData in
            let tokenFile = DaemonHarness.fixtures.appendingPathComponent("token-damaged.txt")
            let imported = try DaemonHarness.run(["pair", "--token-file", tokenFile.path],
                                                 environment: ["APPDATA": appData.path])
            let first = try XCTUnwrap(MirrorPairing.parsePairURL(try XCTUnwrap(imported.0.first)))
            let (lines, error, status) = try DaemonHarness.run(
                ["pair", "--rotate"], environment: ["APPDATA": appData.path])
            XCTAssertEqual(status, 0, error.joined(separator: "\n"))
            let rotated = try XCTUnwrap(MirrorPairing.parsePairURL(try XCTUnwrap(lines.first)))
            XCTAssertNotEqual(rotated.token, first.token)
            XCTAssertEqual(rotated.token.count, MirrorPairing.tokenLength)
            XCTAssertEqual(MirrorPairing.normalize(rotated.token), rotated.token,
                           "already normalized: every character is in the alphabet")
            XCTAssertEqual(try self.storedToken(appData), rotated.token)
        }
    }

    /// `--port` changes the endpoint the QR advertises.
    func testPairHonoursPort() throws {
        try DaemonHarness.scratch { appData in
            let (lines, _, status) = try DaemonHarness.run(
                ["pair", "--rotate", "--port", "47825"],
                environment: ["APPDATA": appData.path])
            XCTAssertEqual(status, 0)
            let pairing = try XCTUnwrap(MirrorPairing.parsePairURL(try XCTUnwrap(lines.first)))
            XCTAssertTrue(pairing.endpoints.contains { $0.hasSuffix(":47825") },
                          pairing.endpoints.joined(separator: ", "))
        }
    }

    // MARK: plumbing

    /// The stored token, read back the way `loadOrCreate` reads it.
    private func storedToken(_ appData: URL) throws -> String {
        let url = appData.appendingPathComponent("Infinitus").appendingPathComponent("pair-token")
        return MirrorPairing.normalize(try String(contentsOf: url, encoding: .utf8))
    }
}
