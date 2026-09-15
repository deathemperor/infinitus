import Foundation
#if canImport(Glibc)
import Glibc   // rename(2), errno
#endif

/// Where the identity secret and store tokens live. The Mac app supplies
/// a keychain-backed implementation (plan 5); the CLI, Linux and tests
/// use owner-only files.
public protocol TeamSecrets {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ data: Data) throws
    func delete(_ name: String)
}

/// One file per secret in a 0700 directory, each 0600, written through a
/// temp file and rename so a crash never leaves a half-written key.
public struct FileSecrets: TeamSecrets {
    public let dir: URL

    public enum SecretsError: Error, Equatable { case badName, writeFailed(Int32) }

    public init(dir: URL) { self.dir = dir }

    private func url(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw SecretsError.badName }
        return dir.appendingPathComponent(name)
    }

    public func read(_ name: String) -> Data? {
        guard let u = try? url(name) else { return nil }
        return try? Data(contentsOf: u)
    }

    public func write(_ name: String, _ data: Data) throws {
        let target = try url(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".\(name).tmp-\(UUID().uuidString)")
        var renamed = false
        defer { if !renamed { try? FileManager.default.removeItem(at: tmp) } }
        try data.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // rename(2) replaces the target in one step: a concurrent reader
        // sees either the old secret or the new one, never none.
        #if os(Windows)
        // No rename(2) semantics on NTFS from Foundation; remove + move
        // is the closest (#171 parity).
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        #else
        guard rename(tmp.path, target.path) == 0 else { throw SecretsError.writeFailed(errno) }
        #endif
        renamed = true
    }

    public func delete(_ name: String) {
        guard let u = try? url(name) else { return }
        try? FileManager.default.removeItem(at: u)
    }
}
