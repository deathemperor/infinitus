import Foundation
import InfinitusCore

/// The app's own notifications, mirrored to the phone (user 2026-09-03
/// "working sessions on LA doesn't seem to get updated" → "build the
/// APNs part"; the Live Activity cards it fed are gone, #1041): the
/// phone registers its alert token over the mirror, this posts straight
/// to APNs with the team's .p8 key (keychain, pasted in the Devices pane
/// — never argv, never shown).
@MainActor
final class LiveActivityPusher: ObservableObject {
    static let keyIDKey = "apns_key_id"
    static let teamIDKey = "apns_team_id"
    private static let registrationsKey = "apns_activity_registrations"

    @Published var keyID: String {
        didSet {
            AppDefaults.standard.set(keyID, forKey: Self.keyIDKey)
            keyStored = false
            recheckKey()
        }
    }
    @Published var teamID: String { didSet { AppDefaults.standard.set(teamID, forKey: Self.teamIDKey) } }
    @Published private(set) var keyStored = false
    @Published private(set) var registrations: [String: ActivityPushRegistration] = [:]
    /// One line for the pane: the last push's outcome.
    @Published private(set) var lastResult: String?
    /// The last push's outcome per registration slot, for the `apns` read
    /// (#1272 follow-up); in memory only, like `lastResult`.
    @Published private(set) var lastPushes: [String: ApnsStatus.LastPush] = [:]
    var log: ((String, String) -> Void)?

    private var jwt: (token: String, mintedAt: Date)?
    private var inFlight: Set<String> = []
    /// The thread card each phone last got (#1047), by device id: a
    /// repeat of the same state is not sent again.
    private var lastAgentActivity: [String: AgentActivityState] = [:]
    /// When that card was last started or updated, by device id (#1265).
    private var lastAgentActivityAt: [String: Date] = [:]

    init() {
        let defaults = AppDefaults.standard
        keyID = defaults.string(forKey: Self.keyIDKey) ?? ""
        teamID = defaults.string(forKey: Self.teamIDKey) ?? ""
        if let data = defaults.data(forKey: Self.registrationsKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Per-entry decode (#1041): a store saved before the card
            // kinds retired still holds `working`/`revival`/`*-start`
            // slots the phone never withdrew. Decoding the dictionary in
            // one shot would throw on those and lose the `alert` token
            // with them; keep whatever entries still decode.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (slot, value) in object {
                    guard let entryData = try? JSONSerialization.data(withJSONObject: value),
                          let registration = try? decoder.decode(ActivityPushRegistration.self, from: entryData)
                    else { continue }
                    registrations[slot] = registration
                }
            }
        }
        keyStored = !keyID.isEmpty && Keychain.read(account: keyID, service: Keychain.apnsService) != nil
    }

    var configured: Bool { keyStored && !teamID.isEmpty && !keyID.isEmpty }

    /// The keychain answer is not final: a key stored by another instance,
    /// or a grant made after launch, used to need a relaunch before any
    /// push went out (#845). While the answer is no, ask again — one
    /// attribute lookup, never a prompt (`Keychain.read` skips UI).
    private func recheckKey() {
        guard !keyStored, !keyID.isEmpty else { return }
        keyStored = Keychain.read(account: keyID, service: Keychain.apnsService) != nil
    }

    /// The pasted .p8 (PEM) goes to the keychain under the key id; an
    /// empty paste forgets it.
    func storeKey(pem: String) {
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyID.isEmpty else { lastResult = "set the Key ID first"; return }
        if trimmed.isEmpty {
            Keychain.delete(account: keyID, service: Keychain.apnsService)
            keyStored = false
            lastResult = "key forgotten"
            return
        }
        guard trimmed.contains("BEGIN PRIVATE KEY") else {
            lastResult = "that isn't a .p8 key (expected -----BEGIN PRIVATE KEY-----)"
            return
        }
        // Prove it signs before keeping it.
        do {
            _ = try APNsJWT.make(.init(keyID: keyID, teamID: teamID.isEmpty ? "-" : teamID, privateKeyPEM: trimmed))
        } catch {
            lastResult = "that key doesn't parse as a P-256 private key"
            return
        }
        keyStored = Keychain.write(account: keyID, value: trimmed, service: Keychain.apnsService)
        jwt = nil
        lastResult = keyStored ? "key stored in the keychain" : "couldn't write the keychain"
    }

    // MARK: registrations

    func register(_ registration: ActivityPushRegistration) {
        var fresh = registration
        fresh.registeredAt = Date()
        let changed = registrations[fresh.slot]?.token != fresh.token
        registrations[fresh.slot] = fresh
        if changed {
            lastPushes[fresh.slot] = nil
            log?("📲", "\(fresh.deviceName) registered a \(fresh.kind.rawValue) push token")
        }
        persist()
    }

    /// A phone forgotten in Settings › Devices: nothing is pushed to it
    /// any more. It registers afresh if it opens the app again.
    func forget(deviceId: String) {
        let slots = registrations.values.filter { $0.deviceId == deviceId }.map(\.slot)
        guard !slots.isEmpty else { return }
        for slot in slots {
            registrations[slot] = nil
        }
        log?("📲", "forgot \(slots.count) push token\(slots.count == 1 ? "" : "s") of a forgotten phone")
        persist()
    }

    /// One registration withdrawn by the phone itself (#572 G6: the
    /// fork's "Alerts from Mac" switched off) — without this, the last
    /// `alert` token kept getting banners until APNs rotated it. False
    /// when nothing was registered under that slot.
    @discardableResult
    func forget(slot: String) -> Bool {
        guard let gone = registrations.removeValue(forKey: slot) else { return false }
        log?("📲", "\(gone.deviceName) withdrew its \(gone.kind.rawValue) push token")
        persist()
        return true
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        AppDefaults.standard.set(try? encoder.encode(registrations), forKey: Self.registrationsKey)
    }

    /// The app's own notifications, mirrored to every phone that
    /// registered an alert token (issue #3). No phone → nothing sent,
    /// and the reach says so.
    @discardableResult
    func pushAlert(title: String, body: String) -> PushReach {
        var reach = PushReach()
        guard configured else { return reach }
        for registration in registrations.values where registration.kind == .alert {
            if send(LiveActivityPush.alertPayload(title: title, body: body), to: registration, what: "alert") {
                reach.add(device: registration.deviceId, kind: registration.kind.rawValue)
            }
        }
        return reach
    }

    /// The desktop's thread card (#1047): every phone with a live
    /// `agent-activity` token gets the state as an update, a phone with
    /// only a push-to-start token gets it as a start; nil ends the card
    /// and drops the update token (the next start brings a new one).
    /// The push-to-start token stays: it is good for the next card, and
    /// takes over when the live token lapsed (#1265, `liveTokenLapsed`)
    /// with one event line. Answers what went out: a phone whose card already shows this
    /// state, or that holds no token for it, is not a target.
    @discardableResult
    func pushAgentActivity(_ state: AgentActivityState?) -> PushReach {
        var reach = PushReach()
        guard configured else { return reach }
        let devices = Set(registrations.values.filter { $0.kind.isLiveActivity }.map(\.deviceId))
        let now = Date()
        for device in devices {
            var live = registrations[device + "/" + ActivityPushRegistration.Kind.agentActivity.rawValue]
            let start = registrations[device + "/" + ActivityPushRegistration.Kind.agentActivityStart.rawValue]
            if let lapsed = live, start != nil, let sentAt = lastAgentActivityAt[device],
               LiveActivityPush.liveTokenLapsed(registeredAt: lapsed.registeredAt, lastUpdateAt: sentAt, now: now) {
                registrations[lapsed.slot] = nil
                persist()
                lastAgentActivity[device] = nil
                live = nil
                log?("📲", "\(lapsed.deviceName)'s thread card token went quiet — the next card starts afresh")
            }
            guard let state else {
                if let live {
                    if send(LiveActivityPush.agentActivityEndPayload(lastAgentActivity[device]),
                            to: live, what: "end thread card") {
                        reach.add(device: device, kind: live.kind.rawValue)
                    }
                    registrations[live.slot] = nil
                    persist()
                }
                lastAgentActivity[device] = nil
                lastAgentActivityAt[device] = nil
                continue
            }
            if lastAgentActivity[device] == state { continue }
            if let live {
                if send(LiveActivityPush.agentActivityUpdatePayload(state), to: live, what: "update thread card",
                        priority: "5") {
                    reach.add(device: device, kind: live.kind.rawValue)
                }
            } else if let start {
                if send(LiveActivityPush.agentActivityStartPayload(state), to: start, what: "start thread card") {
                    reach.add(device: device, kind: start.kind.rawValue)
                }
            } else {
                continue
            }
            lastAgentActivity[device] = state
            lastAgentActivityAt[device] = now
        }
        return reach
    }

    // MARK: APNs

    private func bearer() -> String? {
        if let jwt, Date().timeIntervalSince(jwt.mintedAt) < APNsJWT.lifetime { return jwt.token }
        guard let pem = Keychain.read(account: keyID, service: Keychain.apnsService),
              let token = try? APNsJWT.make(.init(keyID: keyID, teamID: teamID, privateKeyPEM: pem))
        else { return nil }
        jwt = (token, Date())
        return token
    }

    /// `retried`: this is the one resend on the other APNs gateway after
    /// a BadDeviceToken — a second refusal writes the token off. True
    /// when the request went out (a key that does not sign sends nothing).
    @discardableResult
    private func send(_ payload: Data, to registration: ActivityPushRegistration, what: String,
                      priority: String = "10", retried: Bool = false) -> Bool {
        let slot = registration.slot
        // Alerts are each their own message (two in one refresh must both land).
        let key = "\(slot)#\(UUID().uuidString)"
        guard !inFlight.contains(key), let bearer = bearer() else { return false }
        inFlight.insert(key)
        var request = URLRequest(url: LiveActivityPush.url(token: registration.token,
                                                           sandbox: registration.isSandbox),
                                 timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        let liveActivity = registration.kind.isLiveActivity
        request.setValue(liveActivity ? LiveActivityPush.topic : LiveActivityPush.bundleID,
                         forHTTPHeaderField: "apns-topic")
        request.setValue(liveActivity ? "liveactivity" : "alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(priority, forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let device = registration.deviceName
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                if code == 200 {
                    self.lastResult = "\(what) → \(device) ok \(Date().formatted(date: .omitted, time: .shortened))"
                    self.lastPushes[slot] = .init(at: Date(), outcome: .landed)
                    if let line = LiveActivityPush.outcomeLine(what: what, device: device, status: code, body: body,
                                                               error: nil, tokenDropped: false) {
                        self.log?("📲", line)
                    }
                    // The token lives on the gateway the phone did not
                    // declare: remember that, so the next push goes
                    // straight there (and a re-registration still wins).
                    if retried, self.registrations[slot]?.token == registration.token {
                        self.registrations[slot] = registration
                        self.persist()
                        self.log?("ℹ️", "Alert push: \(device)'s token is a \(registration.environment) one, not the \(registration.onOtherGateway().environment) it declared — switched gateway")
                    }
                } else if !retried, code == 400, body.contains("BadDeviceToken") {
                    self.send(payload, to: registration.onOtherGateway(), what: what, priority: priority,
                              retried: true)
                } else {
                    let why = error?.localizedDescription ?? "HTTP \(code) \(body)"
                    self.lastResult = "\(what) → \(device) failed: \(why)"
                    self.lastPushes[slot] = .init(at: Date(), outcome: .failed, detail: LiveActivityPush.failureDetail(
                        status: code, body: body, error: error?.localizedDescription))
                    // A dead token will never work again — drop it.
                    let dead = LiveActivityPush.isDeadToken(status: code, body: body)
                    if let line = LiveActivityPush.outcomeLine(what: what, device: device, status: code, body: body,
                                                               error: error?.localizedDescription, tokenDropped: dead) {
                        self.log?("⚠️", line)
                    }
                    if dead {
                        self.registrations[slot] = nil
                        self.persist()
                    } else if body.contains("InvalidProviderToken") || body.contains("ExpiredProviderToken") {
                        self.jwt = nil
                    }
                }
            }
        }.resume()
        return true
    }
}
