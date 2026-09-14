import Foundation

/// The `test-connection` verb's reply (#1177): the fork's Engines page
/// probes an engine it never holds the key for — the keychain credential
/// is used here — and shows `ok` with the latency, or the engine's own
/// words. Bounded: a dead URL answers as a timeout inside
/// `timeoutSeconds` instead of holding the socket.
public enum ConnectionTest {
    public static let targets = ["cliproxy", "9router"]
    public static let timeoutSeconds: Double = 5

    public struct Reply: Equatable, Sendable {
        public let ok: Bool
        public let latencyMs: Int?
        public let version: String?
        public let error: String?

        public static func reached(latencyMs: Int, version: String? = nil) -> Reply {
            Reply(ok: true, latencyMs: latencyMs, version: version, error: nil)
        }
        public static func failed(_ error: String) -> Reply {
            Reply(ok: false, latencyMs: nil, version: nil, error: error)
        }

        /// `{ok, latencyMs?, version?, error?}` — absent fields are absent,
        /// never null, so the fork's optional decode reads them as missing.
        public var fields: [String: JSONValue] {
            var out: [String: JSONValue] = ["ok": .bool(ok)]
            if let latencyMs { out["latencyMs"] = .number(Double(latencyMs)) }
            if let version { out["version"] = .string(version) }
            if let error { out["error"] = .string(error) }
            return out
        }
    }

    public struct TimedOut: Error, Equatable {}

    /// Runs `body` against a deadline: whichever finishes first answers,
    /// the other is cancelled. A probe whose transport ignores the
    /// cancellation still stops mattering — the reply is already out.
    public static func withDeadline<T: Sendable>(seconds: Double = timeoutSeconds,
                                                 _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
