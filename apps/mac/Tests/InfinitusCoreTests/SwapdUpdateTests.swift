import XCTest
@testable import InfinitusCore

#if !os(iOS)
/// An engine release installed from the Engines page (#1577): the release
/// read, the checksum enforced, the binary asked its version, and the
/// locator's rule that the copy outranks the bundle only while newer.
final class SwapdUpdateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("swapd-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private let releaseJSON = Data("""
    {"tag_name":"v0.3.3","assets":[
      {"name":"swapd-0.3.3-aarch64-apple-darwin.tar.gz","browser_download_url":"https://x/a.tgz"},
      {"name":"swapd-0.3.3-aarch64-apple-darwin.tar.gz.sha256","browser_download_url":"https://x/a.sha"},
      {"name":"swapd-0.3.3-x86_64-apple-darwin.tar.gz","browser_download_url":"https://x/b.tgz"},
      {"name":"swapd-0.3.3-x86_64-apple-darwin.tar.gz.sha256","browser_download_url":"https://x/b.sha"}]}
    """.utf8)

    func testVersionsCompareNumericallyAndAPrereleaseSortsBeforeItsRelease() {
        XCTAssertEqual(EngineVersion.compare("0.3.10", "0.3.2"), 1)
        XCTAssertEqual(EngineVersion.compare("v0.3.2", "swapd 0.3.2"), 0)
        XCTAssertEqual(EngineVersion.compare("0.4.0-rc.1", "0.4.0"), -1)
        XCTAssertEqual(EngineVersion.compare("1.0", "0.9.9"), 1)
        XCTAssertTrue(EngineVersion.isNewer("0.3.3", than: "0.3.2"))
        XCTAssertFalse(EngineVersion.isNewer("0.3.2", than: "0.3.2"))
        XCTAssertTrue(EngineVersion.isNewer("0.3.2", than: nil), "a copy with no bundle to beat is the engine")
        XCTAssertFalse(EngineVersion.isNewer(nil, than: "0.3.2"))
    }

    func testTheReleaseIsReadForThePlatform() throws {
        let arm = try XCTUnwrap(SwapdUpdate.release(from: releaseJSON, architecture: "aarch64"))
        XCTAssertEqual(arm.version, "0.3.3")
        XCTAssertEqual(arm.asset.absoluteString, "https://x/a.tgz")
        XCTAssertEqual(arm.checksum.absoluteString, "https://x/a.sha")
        XCTAssertEqual(arm.assetName, "swapd-0.3.3-aarch64-apple-darwin.tar.gz")
        XCTAssertEqual(try SwapdUpdate.release(from: releaseJSON, architecture: "x86_64")?.asset.absoluteString, "https://x/b.tgz")
        XCTAssertNil(try SwapdUpdate.release(from: releaseJSON, architecture: "riscv"), "no asset, no release")
    }

    func testTheChecksumLineIsTheDigestAndNothingElse() {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(SwapdUpdate.expectedDigest(Data("\(hex)  swapd-0.3.3-aarch64-apple-darwin.tar.gz\n".utf8)), hex)
        XCTAssertNil(SwapdUpdate.expectedDigest(Data("not a digest\n".utf8)))
        XCTAssertEqual(SwapdUpdate.digest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTheUpdateOutranksTheBundleOnlyWhileNewer() {
        let home = "/fixture"
        let update = "/fixture/Library/Application Support/Infinitus/engines/swapd-update/swapd"
        let bundled = "/fixture/Infinitus.app/Contents/MacOS/swapd"
        let newer = SwapdLocator.defaultCandidates(home: home, bundledExecutableDirectory: "/fixture/Infinitus.app/Contents/MacOS",
                                                   updateBinary: update, updateVersion: "0.3.3", bundledVersion: "0.3.2")
        XCTAssertEqual(Array(newer.prefix(2)), [update, bundled])
        let stale = SwapdLocator.defaultCandidates(home: home, bundledExecutableDirectory: "/fixture/Infinitus.app/Contents/MacOS",
                                                   updateBinary: update, updateVersion: "0.3.2", bundledVersion: "0.3.2")
        XCTAssertEqual(stale.first, bundled)
        XCTAssertFalse(stale.contains(update), "an update the bundle caught up with is skipped, as a PATH copy is (#1530)")
        let none = SwapdLocator.defaultCandidates(home: home, bundledExecutableDirectory: nil, updateBinary: update, updateVersion: nil, bundledVersion: nil)
        XCTAssertFalse(none.contains(update))
        XCTAssertNil(SwapdUpdate.bundledVersion(info: [:]))
        XCTAssertEqual(SwapdUpdate.bundledVersion(info: ["InfinitusSwapdVersion": "0.3.2"]), "0.3.2")
    }

    /// The install with the network and the two subprocesses faked: the
    /// tarball's digest is checked against the checksum file before `tar`
    /// runs, the unpacked binary is asked its version, and the copy lands
    /// with its sidecar. A wrong digest installs nothing.
    func testInstallVerifiesTheDigestAndTheBinaryBeforePuttingItInPlace() async throws {
        let archive = Data("pretend tarball".utf8)
        let location = SwapdUpdate.Location(appSupport: dir)
        let release = SwapdUpdate.Release(version: "0.3.3", asset: URL(string: "https://x/a.tgz")!,
                                          checksum: URL(string: "https://x/a.sha")!,
                                          assetName: "swapd-0.3.3-aarch64-apple-darwin.tar.gz")
        final class Log: @unchecked Sendable { var runs: [[String]] = [] }
        let log = Log()
        func updater(digest: String) -> SwapdUpdater {
            SwapdUpdater(location: location, fetch: { url in
                url.absoluteString.hasSuffix(".sha") ? Data("\(digest)  a.tgz\n".utf8) : archive
            }, run: { binary, args in
                log.runs.append([binary] + args)
                if binary == "/usr/bin/tar" {
                    // Stand in for the extraction: the binary appears where tar would put it.
                    let out = URL(fileURLWithPath: args[3]).appendingPathComponent("swapd")
                    try Data("#!/bin/sh\n".utf8).write(to: out)
                    return Data()
                }
                return Data(#"{"schemaVersion":1,"version":"0.3.3"}"#.utf8)
            })
        }
        do {
            try await updater(digest: String(repeating: "00", count: 32)).install(release)
            XCTFail("a wrong digest must refuse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"), error.localizedDescription)
            XCTAssertTrue(log.runs.isEmpty, "nothing runs before the digest matches")
            XCTAssertNil(location.installedVersion())
        }
        try await updater(digest: SwapdUpdate.digest(archive)).install(release)
        XCTAssertEqual(location.installedVersion(), "0.3.3")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: location.binary.path))
        XCTAssertEqual(log.runs.first?.first, "/usr/bin/tar")
        XCTAssertEqual(log.runs.last?.suffix(2).map { $0 }, ["version", "--json"])
    }
}
#endif
