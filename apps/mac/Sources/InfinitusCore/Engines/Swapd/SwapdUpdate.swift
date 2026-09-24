import Crypto
import Foundation

#if !os(iOS)
/// A swapd release installed from the Engines page (#1577), outside the
/// bundle: the copy lives under Application Support with a sidecar naming
/// its version, and `SwapdLocator` takes it ahead of the bundled copy only
/// while it is the newer of the two — a release whose bundle catches up
/// outranks it again, so the #1530 rule (the bundle over a stale copy)
/// holds for this copy as for one on the PATH.
public enum SwapdUpdate {
    public static let repository = "deathemperor/swapd"
    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public struct Location: Sendable {
        public let directory: URL
        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            directory = home.appendingPathComponent("Library/Application Support/Infinitus/engines/swapd-update")
        }
        public var binary: URL { directory.appendingPathComponent("swapd") }
        public var version: URL { directory.appendingPathComponent("VERSION") }

        /// The installed copy's version, or nil when none is installed.
        public func installedVersion() -> String? {
            guard FileManager.default.isExecutableFile(atPath: binary.path),
                  let text = try? String(contentsOf: version, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The build's own engine, as `make-app.sh` stamped it into Info.plist
    /// (`InfinitusSwapdVersion`); nil for a source build with no engine beside it.
    public static func bundledVersion(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> String? {
        (info["InfinitusSwapdVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The platform's asset name: `swapd-<v>-aarch64-apple-darwin.tar.gz`.
    public static var architecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }

    public struct Release: Sendable, Equatable {
        public let version: String
        public let asset: URL
        public let checksum: URL
        public let assetName: String
    }

    /// What `releases/latest` says, for this platform; nil when the release
    /// has no asset for it (a release still uploading, an unknown platform).
    public static func release(from json: Data, architecture: String = architecture) throws -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Doc: Decodable { let tag_name: String; let assets: [Asset] }
        let doc = try JSONDecoder().decode(Doc.self, from: json)
        let version = EngineVersion.normalize(doc.tag_name)
        let name = "swapd-\(version)-\(architecture)-apple-darwin.tar.gz"
        guard let asset = doc.assets.first(where: { $0.name == name }),
              let checksum = doc.assets.first(where: { $0.name == name + ".sha256" }) else { return nil }
        return Release(version: version, asset: asset.browser_download_url,
                       checksum: checksum.browser_download_url, assetName: name)
    }

    /// The hex digest a `.sha256` file names (`<hex>  <filename>`).
    public static func expectedDigest(_ checksumFile: Data) -> String? {
        let text = String(decoding: checksumFile, as: UTF8.self)
        guard let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).first,
              first.count == 64, first.allSatisfy(\.isHexDigit) else { return nil }
        return first.lowercased()
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// What the check verb answers: the running copy, the newest release for
    /// this platform, and whether the second is newer than the first.
    public struct Check: Encodable, Sendable {
        public let engine = "swapd"
        public let current: String?
        public let latest: String?
        public let updatable: Bool
        public let installed: String?
        public let error: String?

        public init(current: String?, latest: String?, updatable: Bool, installed: String?, error: String?) {
            self.current = current
            self.latest = latest
            self.updatable = updatable
            self.installed = installed
            self.error = error
        }
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}

/// Dotted release versions (`0.3.2`, `v0.3.10`, `0.4.0-rc.1`), compared
/// numerically per component; a prerelease sorts before its release.
public enum EngineVersion {
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("swapd ") { s = String(s.dropFirst("swapd ".count)) }
        if s.hasPrefix("v") { s = String(s.dropFirst()) }
        return s
    }

    /// Positive when `a` is newer than `b`, zero when equal, negative otherwise.
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> (numbers: [Int], pre: String?) {
            let n = normalize(v)
            let split = n.split(separator: "-", maxSplits: 1)
            let numbers = split.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            return (numbers, split.count > 1 ? String(split[1]) : nil)
        }
        let (an, ap) = parts(a), (bn, bp) = parts(b)
        for i in 0..<max(an.count, bn.count) {
            let x = i < an.count ? an[i] : 0, y = i < bn.count ? bn[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        switch (ap, bp) {
        case (nil, nil): return 0
        case (nil, _): return 1
        case (_, nil): return -1
        case (let x?, let y?): return x == y ? 0 : (x > y ? 1 : -1)
        }
    }

    public static func isNewer(_ a: String?, than b: String?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        return compare(a, b) > 0
    }
}

/// Downloads and installs a release: the tarball and its `.sha256` from the
/// release, the digest checked before anything is unpacked, the binary asked
/// for its version before it is put in place. `fetch` and `run` are injected
/// so a test never reaches GitHub.
public actor SwapdUpdater {
    public typealias Fetch = @Sendable (URL) async throws -> Data
    public typealias Run = @Sendable (_ binary: String, _ arguments: [String]) async throws -> Data

    private let location: SwapdUpdate.Location
    private let fetch: Fetch
    private let run: Run

    public init(location: SwapdUpdate.Location = SwapdUpdate.Location(),
                fetch: @escaping Fetch = { url in
                    var request = URLRequest(url: url)
                    request.setValue("Infinitus", forHTTPHeaderField: "User-Agent")
                    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw SwapdUpdate.Failure("\(url.host ?? "GitHub") answered \(http.statusCode)")
                    }
                    return data
                },
                run: @escaping Run = { binary, arguments in try await SwapdCLI(binaryPath: binary).run(arguments) }) {
        self.location = location
        self.fetch = fetch
        self.run = run
    }

    public func latest() async throws -> SwapdUpdate.Release? {
        try SwapdUpdate.release(from: await fetch(SwapdUpdate.latestReleaseURL))
    }

    /// Installs `release` under the update location; the caller relaunches
    /// the app so the locator and the launch agent pick it up.
    public func install(_ release: SwapdUpdate.Release) async throws {
        let archive = try await fetch(release.asset)
        guard let expected = SwapdUpdate.expectedDigest(try await fetch(release.checksum)) else {
            throw SwapdUpdate.Failure("the release's checksum file is not a SHA-256 line")
        }
        let actual = SwapdUpdate.digest(archive)
        guard actual == expected else {
            throw SwapdUpdate.Failure("the download's SHA-256 does not match the release's (\(actual.prefix(12))… vs \(expected.prefix(12))…)")
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("swapd-update-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let tarball = staging.appendingPathComponent(release.assetName)
        try archive.write(to: tarball, options: .atomic)
        // The tarball holds one directory named after the asset, `swapd` inside it.
        _ = try await run("/usr/bin/tar", ["-xzf", tarball.path, "-C", staging.path, "--strip-components", "1",
                                          release.assetName.replacingOccurrences(of: ".tar.gz", with: "") + "/swapd"])
        let unpacked = staging.appendingPathComponent("swapd")
        guard fm.fileExists(atPath: unpacked.path) else {
            throw SwapdUpdate.Failure("the release's tarball holds no swapd binary")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unpacked.path)
        struct Version: Decodable { let version: String }
        let reported = try JSONDecoder().decode(Version.self, from: await run(unpacked.path, ["version", "--json"])).version
        guard EngineVersion.normalize(reported) == release.version else {
            throw SwapdUpdate.Failure("the downloaded binary says it is \(reported), not \(release.version)")
        }
        try fm.createDirectory(at: location.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final = location.binary
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: unpacked, to: final)
        try Data((release.version + "\n").utf8).write(to: location.version, options: .atomic)
    }
}
#endif
