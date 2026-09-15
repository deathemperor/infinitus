import Foundation

/// The `apns` reply (#1178): the push setup a Devices page shows. A
/// registration's token is the phone's push address and stays on the Mac;
/// the reply names the phone and the kind only.
public enum ApnsStatus {
    /// What the last push to one registration did (#1272 follow-up): kept
    /// in memory by the pusher, keyed by slot, so the Devices page reads
    /// the outcome the event log records. `detail` is the HTTP status
    /// and APNs's reason word, or the transport error's text — never a
    /// token.
    public struct LastPush: Equatable, Sendable {
        public enum Outcome: String, Sendable { case landed, failed }
        public var at: Date
        public var outcome: Outcome
        public var detail: String?

        public init(at: Date, outcome: Outcome, detail: String? = nil) {
            self.at = at
            self.outcome = outcome
            self.detail = detail
        }
    }

    public static func fields(keyPresent: Bool, teamId: String, keyId: String,
                              registrations: [ActivityPushRegistration],
                              lastPushes: [String: LastPush] = [:]) -> [String: JSONValue] {
        let rows = registrations
            .sorted { ($0.deviceName, $0.deviceId, $0.kind.rawValue) < ($1.deviceName, $1.deviceId, $1.kind.rawValue) }
            .map { r -> JSONValue in
                var row: [String: JSONValue] = [
                    "deviceId": .string(r.deviceId),
                    "deviceName": .string(r.deviceName),
                    "kind": .string(r.kind.rawValue),
                    "environment": .string(r.environment),
                    "registeredAt": .string(iso.string(from: r.registeredAt)),
                ]
                if let last = lastPushes[r.slot] {
                    var push: [String: JSONValue] = [
                        "at": .string(iso.string(from: last.at)),
                        "kind": .string(r.kind.rawValue),
                        "outcome": .string(last.outcome.rawValue),
                    ]
                    if let detail = last.detail { push["detail"] = .string(detail) }
                    row["lastPush"] = .object(push)
                }
                return .object(row)
            }
        return [
            "keyPresent": .bool(keyPresent),
            "teamId": .string(teamId),
            "keyId": .string(keyId),
            "registrations": .array(rows),
        ]
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
