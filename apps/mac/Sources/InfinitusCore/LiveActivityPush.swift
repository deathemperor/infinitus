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
        /// The phone's push-to-start token (iOS 17.2+) for the thread
        /// card (#1047): the Mac can START the `AgentActivity` activity
        /// with the app closed; iOS then hands the app the activity's
        /// own token, registered as `agent-activity`.
        case agentActivityStart = "agent-activity-start"
        /// One live thread card's update token.
        case agentActivity = "agent-activity"

        /// Sent on the `liveactivity` push type and topic, not `alert`.
        public var isLiveActivity: Bool { self != .alert }
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
    public static let topic = bundleID + ".push-type.liveactivity"
    /// The expo-widgets layout the phone registers for the thread card
    /// (#1047): upstream's `AgentActivity`, one attributes type for
    /// every expo activity, the state as a JSON STRING under `props` —
    /// the envelope T3's relay sends, so the widget needs no change.
    public static let agentActivityName = "AgentActivity"
    public static let expoAttributesType = "LiveActivityAttributes"
    /// Updates flow on thread events only, so a healthy card can be
    /// silent for minutes; iOS dims it after this without one.
    public static let staleAfter: TimeInterval = 10 * 60
    /// How long an ended card with a final state stays on the screen,
    /// and how fast one ended without a state goes.
    public static let dismissAfter: TimeInterval = 5 * 60
    public static let contentlessDismissAfter: TimeInterval = 15

    /// Whether a live card's token is taken as ended on the phone (#1265):
    /// APNs answers 200 to an update of an ended activity, so a card the
    /// phone dismissed or aged out leaves a token the Mac would update
    /// into nothing forever, never reaching for the push-to-start token.
    /// The phone re-offers a running card's token on every foreground; a
    /// token not re-offered since the last update, with that update
    /// older than twice `staleAfter`, is written off.
    public static func liveTokenLapsed(registeredAt: Date, lastUpdateAt: Date, now: Date = Date()) -> Bool {
        registeredAt <= lastUpdateAt && now.timeIntervalSince(lastUpdateAt) > staleAfter * 2
    }

    /// The event line for a push's outcome, or nil when none is worth a
    /// row (#941 follow-up): the log used to carry only "Alert push
    /// failed: …" for every kind, and no success at all, so a thread
    /// card's start could not be read from the Mac. A started or ended
    /// card gets a line (one per card; its updates only refresh the
    /// pane's last result), and a failure names what was being sent,
    /// APNs's reason word, and whether the token was written off.
    public static func outcomeLine(what: String, device: String, status: Int, body: String,
                                   error: String?, tokenDropped: Bool) -> String? {
        if status == 200 {
            switch what {
            case "start thread card": return "thread card started on \(device) (push-to-start)"
            case "end thread card": return "thread card ended on \(device)"
            default: return nil
            }
        }
        let why = failureDetail(status: status, body: body, error: error)
        return "\(what) → \(device) failed: \(why)" + (tokenDropped ? " — token dropped" : "")
    }

    /// A failed push in a few words: the transport error's text, else the
    /// HTTP status with APNs's `reason` word (the raw body when it has
    /// none). Shared by the event line and the `apns` read's `lastPush`.
    public static func failureDetail(status: Int, body: String, error: String?) -> String {
        if let error { return error }
        let reason = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["reason"] as? String
        return "HTTP \(status) \(reason ?? body)"
    }

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

    /// The expo-widgets content state: the layout's name and the props
    /// as one JSON string.
    static func contentState(_ state: AgentActivityState) -> [String: Any] {
        ["name": agentActivityName, "props": state.props]
    }

    /// `event: start` on a push-to-start token: attributes stay empty,
    /// `input-push-token` asks iOS to hand the app the new activity's
    /// token, and the alert wakes the screen with the card's headline.
    public static func agentActivityStartPayload(_ state: AgentActivityState, now: Date = Date()) -> Data {
        let timestamp = Int(now.timeIntervalSince1970)
        return data(["aps": [
            "timestamp": timestamp, "event": "start",
            "attributes-type": expoAttributesType, "attributes": [String: Any](),
            "input-push-token": 1,
            "alert": ["title": state.title, "body": state.subtitle],
            "content-state": contentState(state),
            "stale-date": timestamp + Int(staleAfter),
        ]])
    }

    /// `event: update` — new content for the running card.
    public static func agentActivityUpdatePayload(_ state: AgentActivityState, now: Date = Date()) -> Data {
        let timestamp = Int(now.timeIntervalSince1970)
        return data(["aps": [
            "timestamp": timestamp, "event": "update",
            "content-state": contentState(state),
            "stale-date": timestamp + Int(staleAfter),
        ]])
    }

    /// `event: end` — with the last state it lingers a while; without
    /// one it goes at once rather than freeze whatever it last showed.
    public static func agentActivityEndPayload(_ state: AgentActivityState?, now: Date = Date()) -> Data {
        let timestamp = Int(now.timeIntervalSince1970)
        var aps: [String: Any] = [
            "timestamp": timestamp, "event": "end",
            "dismissal-date": timestamp + Int(state == nil ? contentlessDismissAfter : dismissAfter),
        ]
        if let state { aps["content-state"] = contentState(state) }
        return data(["aps": aps])
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
