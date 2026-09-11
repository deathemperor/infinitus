import XCTest
@testable import InfinitusCore

final class TeamIdentityExportTests: XCTestCase {
    let secret = Data((0..<32).map { UInt8($0) })

    func testRoundTripAndWrongPassphrase() throws {
        let file = try TeamIdentityExport.export(secret: secret, passphrase: "correct horse", rounds: 1_000)
        XCTAssertEqual(try TeamIdentityExport.import(file, passphrase: "correct horse"), secret)
        XCTAssertThrowsError(try TeamIdentityExport.import(file, passphrase: "wrong")) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .badPassphrase)
        }
        let decoded = try JSONDecoder().decode(TeamIdentityExport.File.self, from: file)
        XCTAssertEqual(decoded.v, 1); XCTAssertEqual(decoded.kdf, "pbkdf2-hmac-sha256"); XCTAssertEqual(decoded.rounds, 1_000)
        XCTAssertEqual(Data(base64Encoded: decoded.salt)?.count, 16)
        XCTAssertEqual(Data(base64Encoded: decoded.nonce)?.count, 12)
        XCTAssertEqual(TeamIdentityExport.defaultRounds, 600_000)
    }

    func testTwoExportsDiffer() throws {
        XCTAssertNotEqual(try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000),
                          try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000), "fresh salt and nonce")
    }

    func testHeaderIsAuthenticated() throws {
        let file = try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000)
        var doc = try JSONDecoder().decode(TeamIdentityExport.File.self, from: file)
        doc.rounds = 999   // an attacker lowering the work factor
        let tampered = try JSONEncoder().encode(doc)
        XCTAssertThrowsError(try TeamIdentityExport.import(tampered, passphrase: "p"))
    }

    func testRejectsMalformedAndAbsurdRounds() throws {
        XCTAssertThrowsError(try TeamIdentityExport.import(Data("{}".utf8), passphrase: "p")) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .malformed)
        }
        var doc = try JSONDecoder().decode(TeamIdentityExport.File.self, from: try TeamIdentityExport.export(secret: secret, passphrase: "p", rounds: 1_000))
        doc.rounds = 50_000_000
        XCTAssertThrowsError(try TeamIdentityExport.import(try JSONEncoder().encode(doc), passphrase: "p")) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .malformed)
        }
        XCTAssertThrowsError(try TeamIdentityExport.export(secret: Data([1, 2]), passphrase: "p", rounds: 1_000)) {
            XCTAssertEqual($0 as? TeamIdentityExport.ExportError, .badSecret)
        }
    }

    func testWriteCreatesExclusivelyWithOwnerOnlyPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idexp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("me.json")
        try TeamIdentityExport.write(Data("x".utf8), to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertThrowsError(try TeamIdentityExport.write(Data("y".utf8), to: url), "never overwrites (nor follows) an existing path")
        XCTAssertEqual(try Data(contentsOf: url), Data("x".utf8))
    }
}
