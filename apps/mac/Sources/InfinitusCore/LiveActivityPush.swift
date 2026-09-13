import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Alert pushes (APNs) — the app's own notifications, mirrored to the
// phone (issue #3). The phone registers its token with the Mac over the
// mirror (`POST /activities/token`); the Mac posts straight to Apple with
// a token-based (.p8) key it holds in the keychain. No relay, no account
// of ours in between.

/// What the phone tells the Mac: one alert push token.
public struct ActivityPushRegistration: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
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
    public private(set) var environment: String
    /// The phone's theme, so the Mac themes the content the way the
    /// phone would; nil = the Mac's own.
    public let themeID: String?
    public var registeredAt: Date
    /// The key the phone files this Mac under (#144: the hash of its pair
    /// token, stable across renames and primary swaps). nil from a phone
    /// before the field.
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
    /// The same registration declared for the other gateway. A phone
    /// whose declared environment disagrees with its `aps-environment`
    /// entitlement (a Release build signed with a development profile
    /// says "production" while its token is a sandbox one) gets 400
    /// BadDeviceToken from the host it named; the other host is the one
    /// retry before the token is written off (fork phone check, 2026-09-11).
    public func onOtherGateway() -> ActivityPushRegistration {
        var other = self
        other.environment = isSandbox ? "production" : "sandbox"
        return other
    }
    /// One slot per device+kind: a new token for the same replaces it.
    public var slot: String { "\(deviceId)/\(kind.rawValue)" }
}

public enum LiveActivityPush {
    public static let bundleID = "run.infinitus.mobile"

    /// APNs answers that mean the token will never work again, so the
    /// registration is dropped instead of retried every push: 410
    /// Unregistered, 400 BadDeviceToken (after its one resend on the
    /// other gateway — `onOtherGateway`), and 400 DeviceTokenNotForTopic —
    /// a token a phone registered under the previous bundle id (the
    /// 2026-09-05 move to `run.infinitus.mobile`).
    public static func isDeadToken(status: Int, body: String) -> Bool {
        status == 410 || body.contains("BadDeviceToken") || body.contains("DeviceTokenNotForTopic")
    }

    public static func host(sandbox: Bool) -> String {
        sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com"
    }

    public static func url(token: String, sandbox: Bool) -> URL {
        URL(string: "https://\(host(sandbox: sandbox))/3/device/\(token)")!
    }

    /// A plain alert (push-type `alert`, topic = the app's bundle id).
    public static func alertPayload(title: String, body: String) -> Data {
        data(["aps": ["alert": ["title": title, "body": body], "sound": "default"]])
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
