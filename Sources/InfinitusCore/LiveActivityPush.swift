import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Live Activity pushes (APNs) — the Mac keeps the phone's lock screen
// moving with the app closed. The phone registers its tokens with the
// Mac over the mirror (`POST /activities/token`); the Mac posts updates
// straight to Apple with a token-based (.p8) key it holds in the
// keychain. No relay, no account of ours in between.

/// What the phone tells the Mac: one token per activity kind. `start`
/// tokens (iOS 17.2+ push-to-start) let the Mac START an activity when
/// the app isn't running; `update` tokens belong to one live activity.
public struct ActivityPushRegistration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case workingStart = "working-start"
        case working = "working"
        case revivalStart = "revival-start"
        case revival = "revival"
        /// A plain notification token (issue #3): every alert the Mac
        /// posts locally also reaches the phone, no Slack in between.
        case alert = "alert"
    }
    public let kind: Kind
    /// Hex APNs token.
    public let token: String
    public let deviceId: String
    public let deviceName: String
    /// "sandbox" for development-signed builds, "production" otherwise —
    /// Apple routes them to different gateways.
    public let environment: String
    /// The phone's theme, so the Mac themes the content the way the
    /// phone would; nil = the Mac's own.
    public let themeID: String?
    public var registeredAt: Date
    /// The key the phone files this Mac under (#144: the hash of its pair
    /// token, stable across renames and primary swaps). A push-to-start
    /// echoes it into the card's attributes so the phone adopts the card
    /// into the right Mac's slot even when two Macs share a name. nil
    /// from a phone before the field: the card is matched by name.
    public var macId: String?

    public init(kind: Kind, token: String, deviceId: String, deviceName: String,
                environment: String, themeID: String?, registeredAt: Date = Date(), macId: String? = nil) {
        self.kind = kind
        self.token = token
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.environment = environment
        self.themeID = themeID
        self.registeredAt = registeredAt
        self.macId = macId
    }

    public var isSandbox: Bool { environment == "sandbox" }
    /// One slot per device+kind: a new token for the same replaces it.
    public var slot: String { "\(deviceId)/\(kind.rawValue)" }
}

public enum LiveActivityPush {
    public static let bundleID = "run.infinitus.mobile"
    public static let topic = bundleID + ".push-type.liveactivity"

    /// APNs answers that mean the token will never work again, so the
    /// registration is dropped instead of retried every tick: 410
    /// Unregistered, 400 BadDeviceToken, and 400 DeviceTokenNotForTopic —
    /// a token a phone registered under the previous bundle id (the
    /// 2026-09-05 move to `run.infinitus.mobile`).
    public static func isDeadToken(status: Int, body: String) -> Bool {
        status == 410 || body.contains("BadDeviceToken") || body.contains("DeviceTokenNotForTopic")
    }
    public static let workingAttributesType = "WorkingActivity"
    public static let revivalAttributesType = "RevivalActivity"

    public static func host(sandbox: Bool) -> String {
        sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }

    public static func url(token: String, sandbox: Bool) -> URL {
        URL(string: "https://\(host(sandbox: sandbox))/3/device/\(token)")!
    }

    /// `event: update` — new content for a running activity.
    public static func updatePayload<S: Encodable>(state: S, staleDate: Date?, now: Date = Date()) -> Data {
        var aps: [String: Any] = ["timestamp": Int(now.timeIntervalSince1970), "event": "update",
                                  "content-state": json(state)]
        if let staleDate { aps["stale-date"] = Int(staleDate.timeIntervalSince1970) }
        return data(["aps": aps])
    }

    /// `event: end` — final content, gone after `dismissalDate` (nil =
    /// the system default, a few hours).
    public static func endPayload<S: Encodable>(state: S, dismissalDate: Date?, now: Date = Date()) -> Data {
        var aps: [String: Any] = ["timestamp": Int(now.timeIntervalSince1970), "event": "end",
                                  "content-state": json(state)]
        if let dismissalDate { aps["dismissal-date"] = Int(dismissalDate.timeIntervalSince1970) }
        return data(["aps": aps])
    }

    /// `event: start` (push-to-start): the activity's attributes plus
    /// its first content, and — when given — the alert iOS shows as it
    /// appears; without one the activity lands silently. `macId` is the
    /// registration's, echoed so the phone files the card under its Mac.
    public static func startPayload<S: Encodable>(attributesType: String, machine: String, macId: String? = nil,
                                                  state: S, staleDate: Date?, alertTitle: String? = nil,
                                                  alertBody: String? = nil, now: Date = Date()) -> Data {
        var attributes: [String: Any] = ["machine": machine]
        if let macId { attributes["macId"] = macId }
        var aps: [String: Any] = [
            "timestamp": Int(now.timeIntervalSince1970), "event": "start",
            "content-state": json(state),
            "attributes-type": attributesType,
            "attributes": attributes,
        ]
        if let alertTitle, let alertBody { aps["alert"] = ["title": alertTitle, "body": alertBody] }
        if let staleDate { aps["stale-date"] = Int(staleDate.timeIntervalSince1970) }
        return data(["aps": aps])
    }

    /// A plain alert (push-type `alert`, topic = the app's bundle id).
    public static func alertPayload(title: String, body: String) -> Data {
        data(["aps": ["alert": ["title": title, "body": body], "sound": "default"]])
    }

    /// ActivityKit decodes `content-state` with a default-strategy
    /// JSONDecoder (WWDC23 10185: "always decoded using a JSONDecoder with
    /// default decoding strategies … don't use any custom encoding
    /// strategies"), so a Date is seconds since 2001-01-01, never since
    /// 1970 — the latter put the revival countdown 31 years out (#226).
    /// Only the `aps` keys (`timestamp`, `stale-date`, `dismissal-date`)
    /// are Unix seconds.
    private static func json<S: Encodable>(_ state: S) -> Any {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }

    private static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

/// APNs token-based auth: a JWT signed ES256 with the team's .p8 key,
/// good for an hour (Apple refuses one older than that and rate-limits
/// minting under 20 min). Apple platforms only — the Linux tray has no
/// CryptoKit and pushes nothing (parity pending).
public enum APNsJWT {
    public struct Credentials: Sendable, Equatable {
        public let keyID: String
        public let teamID: String
        public let privateKeyPEM: String
        public init(keyID: String, teamID: String, privateKeyPEM: String) {
            self.keyID = keyID
            self.teamID = teamID
            self.privateKeyPEM = privateKeyPEM
        }
    }

    public enum Failure: Error, Equatable { case badKey, unsupported }

    public static func make(_ credentials: Credentials, now: Date = Date()) throws -> String {
        #if canImport(CryptoKit)
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM) }
        catch { throw Failure.badKey }
        let header = base64url(try JSONSerialization.data(
            withJSONObject: ["alg": "ES256", "kid": credentials.keyID], options: [.sortedKeys]))
        let claims = base64url(try JSONSerialization.data(
            withJSONObject: ["iss": credentials.teamID, "iat": Int(now.timeIntervalSince1970)],
            options: [.sortedKeys]))
        let signingInput = Data("\(header).\(claims)".utf8)
        let signature = try key.signature(for: signingInput)
        return "\(header).\(claims).\(base64url(signature.rawRepresentation))"
        #else
        throw Failure.unsupported
        #endif
    }

    /// Mint at most every 50 min: Apple accepts a token for 60.
    public static let lifetime: TimeInterval = 50 * 60

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
