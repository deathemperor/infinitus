import XCTest
@testable import InfinitusCore

final class TeamSecretsTests: XCTestCase {
    func testFileSecretsAreOwnerOnlyAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = FileSecrets(dir: dir)
        XCTAssertNil(s.read("identity"))
        try s.write("identity", Data([1, 2, 3]))
        XCTAssertEqual(s.read("identity"), Data([1, 2, 3]))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("identity").path)
        XCTAssertEqual(mode(attrs), 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual(mode(dirAttrs), 0o700)
        try s.write("identity", Data([9]))
        XCTAssertEqual(s.read("identity"), Data([9]))
        s.delete("identity")
        XCTAssertNil(s.read("identity"))
        XCTAssertThrowsError(try s.write("../escape", Data()))
    }

    func testPathsHonourTheOverrideAndPlatformDefaults() throws {
        let over = TeamPaths.standard(environment: ["INFINITUS_TEAM_DIR": "/tmp/teams-x"], home: "/home/u")
        XCTAssertEqual(over.base.path, "/tmp/teams-x")
        XCTAssertEqual(over.teamDir("t1").path, "/tmp/teams-x/t1")
        XCTAssertEqual(over.configFile("t1").lastPathComponent, "config.json")
        XCTAssertEqual(over.rosterFile("t1").lastPathComponent, "roster.json")
        XCTAssertEqual(over.storeDir("t1").path, "/tmp/teams-x/t1/store")
        XCTAssertEqual(over.secretsDir.path, "/tmp/teams-x/secrets")
        let plain = TeamPaths.standard(environment: [:], home: "/home/u")
        #if os(macOS)
        XCTAssertEqual(plain.base.path, "/home/u/Library/Application Support/Infinitus/teams")
        #else
        XCTAssertEqual(plain.base.path, "/home/u/.local/share/infinitus/teams")
        XCTAssertEqual(TeamPaths.standard(environment: ["XDG_DATA_HOME": "/data"], home: "/home/u").base.path,
                       "/data/infinitus/teams")
        #endif
        // teamIDs lists directories that hold a config.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let p = TeamPaths(base: base)
        try FileManager.default.createDirectory(at: p.teamDir("t2"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: p.teamDir("junk"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: p.configFile("t2"))
        XCTAssertEqual(p.teamIDs(), ["t2"])
    }

    private func mode(_ attrs: [FileAttributeKey: Any]) -> Int? {
        (attrs[.posixPermissions] as? Int) ?? (attrs[.posixPermissions] as? NSNumber)?.intValue
    }

    /// I6: the doc comment promised a temp file and a rename, but the
    /// target was deleted first — a reader in that window saw no secret.
    func testWriteReplacesAnExistingSecretAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = FileSecrets(dir: dir)
        try s.write("identity", Data([0]))

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var missing = 0
            var stop = false
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let reader = FileSecrets(dir: dir)
            while true {
                box.lock.lock(); let stop = box.stop; box.lock.unlock()
                if stop { break }
                if reader.read("identity") == nil {
                    box.lock.lock(); box.missing += 1; box.lock.unlock()
                }
            }
            done.signal()
        }
        for i in 0..<400 { try s.write("identity", Data([UInt8(i % 251)])) }
        box.lock.lock(); box.stop = true; box.lock.unlock()
        done.wait()

        box.lock.lock(); let missing = box.missing; box.lock.unlock()
        XCTAssertEqual(missing, 0, "a concurrent reader saw the secret gone mid-write")
        XCTAssertEqual(s.read("identity"), Data([UInt8(399 % 251)]))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers, [])
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("identity").path)
        XCTAssertEqual(mode(attrs), 0o600)
    }
}
