import Foundation

/// The `apns` reply (#1178): the push setup a Devices page shows. A
/// registration's token is the phone's push address and stays on the Mac;
/// the reply names the phone and the kind only.
public enum ApnsStatus {
    public static func fields(keyPresent: Bool, teamId: String, keyId: String,
                              registrations: [ActivityPushRegistration]) -> [String: JSONValue] {
        let rows = registrations
            .sorted { ($0.deviceName, $0.deviceId, $0.kind.rawValue) < ($1.deviceName, $1.deviceId, $1.kind.rawValue) }
            .map { r -> JSONValue in
                .object([
                    "deviceId": .string(r.deviceId),
                    "deviceName": .string(r.deviceName),
                    "kind": .string(r.kind.rawValue),
                    "environment": .string(r.environment),
                    "registeredAt": .string(iso.string(from: r.registeredAt)),
                ])
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
