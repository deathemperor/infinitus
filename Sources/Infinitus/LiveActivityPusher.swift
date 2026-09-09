import Foundation
import InfinitusCore

/// Keeps the phone's Live Activities moving while the app is closed
/// (user 2026-09-03 "working sessions on LA doesn't seem to get
/// updated" → "build the APNs part"): the phone registers its tokens
/// over the mirror, this posts updates straight to APNs with the team's
/// .p8 key (keychain, pasted in the Devices pane — never argv, never
/// shown). Content comes from the same `LiveActivityBuilder` the phone
/// uses, themed for the phone's theme, so a push and an in-app update
/// never disagree. Push budget: only a real change goes out (the
/// builder's `differs`), at most one per activity per refresh.
@MainActor
final class LiveActivityPusher: ObservableObject {
    static let keyIDKey = "apns_key_id"
    static let teamIDKey = "apns_team_id"
    private static let registrationsKey = "apns_activity_registrations"

    @Published var keyID: String { didSet { UserDefaults.standard.set(keyID, forKey: Self.keyIDKey) } }
    @Published var teamID: String { didSet { UserDefaults.standard.set(teamID, forKey: Self.teamIDKey) } }
    @Published private(set) var keyStored = false
    @Published private(set) var registrations: [String: ActivityPushRegistration] = [:]
    /// One line for the pane: the last push's outcome.
    @Published private(set) var lastResult: String?
    var log: ((String, String) -> Void)?

    private var jwt: (token: String, mintedAt: Date)?
    /// What each registration slot last received, to skip no-op pushes.
    private var lastWorking: [String: WorkingActivityState] = [:]
    private var lastRevival: [String: RevivalActivityState] = [:]
    private var inFlight: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        keyID = defaults.string(forKey: Self.keyIDKey) ?? ""
        teamID = defaults.string(forKey: Self.teamIDKey) ?? ""
        if let data = defaults.data(forKey: Self.registrationsKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            registrations = (try? decoder.decode([String: ActivityPushRegistration].self, from: data)) ?? [:]
        }
        keyStored = !keyID.isEmpty && Keychain.read(account: keyID, service: Keychain.apnsService) != nil
    }

    var configured: Bool { keyStored && !teamID.isEmpty && !keyID.isEmpty }

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
            // A new token is a new activity: nothing pushed to it yet.
            lastWorking[fresh.slot] = nil
            lastRevival[fresh.slot] = nil
            log?("📲", "\(fresh.deviceName) registered a \(fresh.kind.rawValue) push token")
        }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try? encoder.encode(registrations), forKey: Self.registrationsKey)
    }

    // MARK: tick

    /// Called after every fleet refresh with what the phone would see.
    func tick(fleet: EngineFleet, machine: String, themes: [RowTheme], macTheme: RowTheme,
              report: UsageReport?, tokenRate: TokenRate?) {
        guard configured, !registrations.isEmpty else { return }
        for registration in registrations.values {
            let theme = registration.themeID.flatMap { id in themes.first { $0.id == id } } ?? macTheme
            switch registration.kind {
            case .alert:
                continue  // pushAlert, on demand
            case .working:
                let state = LiveActivityBuilder.working(fleet: fleet, theme: theme, report: report,
                                                        tokenRate: tokenRate)
                pushWorking(state, to: registration)
            case .revival:
                let state = LiveActivityBuilder.revival(fleet: fleet, theme: theme)
                pushRevival(state, to: registration)
            case .workingStart:
                // Push-to-start: only when the phone has no live working
                // activity registered (else the update token carries it).
                guard !hasLive(.working, device: registration.deviceId),
                      let state = LiveActivityBuilder.working(fleet: fleet, theme: theme, report: report,
                                                              tokenRate: tokenRate),
                      lastWorking[registration.slot] == nil else { continue }
                lastWorking[registration.slot] = state
                // Silent: the activity appearing is the news, and work
                // starts many times a day.
                send(LiveActivityPush.startPayload(
                        attributesType: LiveActivityPush.workingAttributesType, machine: machine,
                        macId: registration.macId, state: state,
                        staleDate: Date().addingTimeInterval(LiveActivityBuilder.workingStale)),
                     to: registration, what: "start working")
            case .revivalStart:
                guard !hasLive(.revival, device: registration.deviceId),
                      let state = LiveActivityBuilder.revival(fleet: fleet, theme: theme),
                      lastRevival[registration.slot] == nil else { continue }
                lastRevival[registration.slot] = state
                send(LiveActivityPush.startPayload(
                        attributesType: LiveActivityPush.revivalAttributesType, machine: machine,
                        macId: registration.macId, state: state,
                        staleDate: state.revivesAt.addingTimeInterval(60),
                        alertTitle: "All accounts limited",
                        alertBody: "\(state.reviver) \(state.reviveWord) at \(state.revivesAt.formatted(date: .omitted, time: .shortened))"),
                     to: registration, what: "start revival")
            }
        }
        // A start slot re-arms once the condition clears.
        if LiveActivityBuilder.working(fleet: fleet, theme: macTheme, report: nil, tokenRate: nil) == nil {
            for slot in lastWorking.keys where slot.hasSuffix(ActivityPushRegistration.Kind.workingStart.rawValue) {
                lastWorking[slot] = nil
            }
        }
        if LiveActivityBuilder.revival(fleet: fleet, theme: macTheme) == nil {
            for slot in lastRevival.keys where slot.hasSuffix(ActivityPushRegistration.Kind.revivalStart.rawValue) {
                lastRevival[slot] = nil
            }
        }
    }

    /// The tok/min line alone, on the app's rate beat: the last state each
    /// working card received with the fresh rate laid over it, sent only
    /// when the number moved. Push-to-start slots never get an update.
    func pushRate(_ tokenRate: TokenRate?) {
        guard configured else { return }
        for registration in registrations.values where registration.kind == .working {
            guard var state = lastWorking[registration.slot] else { continue }
            let perMinute = tokenRate.flatMap { $0.perMinute > 0 ? $0.perMinute : nil }
            guard state.tokensPerMinute != perMinute else { continue }
            state.tokensPerMinute = perMinute
            state.tokenFraction = tokenRate?.fraction ?? 0
            lastWorking[registration.slot] = state
            send(LiveActivityPush.updatePayload(state: state,
                                                staleDate: Date().addingTimeInterval(LiveActivityBuilder.workingStale)),
                 to: registration, what: "update rate")
        }
    }

    /// An update token registered in the last 8 h (an activity's max run).
    private func hasLive(_ kind: ActivityPushRegistration.Kind, device: String) -> Bool {
        guard let live = registrations["\(device)/\(kind.rawValue)"] else { return false }
        return Date().timeIntervalSince(live.registeredAt) < 8 * 3600
    }

    private func pushWorking(_ state: WorkingActivityState?, to registration: ActivityPushRegistration) {
        let slot = registration.slot
        if let state {
            if let previous = lastWorking[slot], !LiveActivityBuilder.differs(previous, state) { return }
            lastWorking[slot] = state
            send(LiveActivityPush.updatePayload(state: state,
                                                staleDate: Date().addingTimeInterval(LiveActivityBuilder.workingStale)),
                 to: registration, what: "update working")
        } else if let previous = lastWorking[slot] {
            // Nothing working any more: end it, and forget the token —
            // the next activity brings a new one.
            lastWorking[slot] = nil
            send(LiveActivityPush.endPayload(state: previous, dismissalDate: Date()), to: registration,
                 what: "end working")
            registrations[slot] = nil
            persist()
        }
    }

    private func pushRevival(_ state: RevivalActivityState?, to registration: ActivityPushRegistration) {
        let slot = registration.slot
        if let state {
            if lastRevival[slot] == state { return }
            lastRevival[slot] = state
            send(LiveActivityPush.updatePayload(state: state, staleDate: state.revivesAt.addingTimeInterval(60)),
                 to: registration, what: "update revival")
        } else if var previous = lastRevival[slot] {
            previous.revived = true
            lastRevival[slot] = nil
            send(LiveActivityPush.endPayload(state: previous, dismissalDate: Date().addingTimeInterval(120)),
                 to: registration, what: "end revival")
            registrations[slot] = nil
            persist()
        }
    }

    /// The app's own notifications, mirrored to every phone that
    /// registered an alert token (issue #3). No phone → nothing sent.
    /// `unlessRevival`: a phone whose countdown activity is live (or
    /// registered to start, with its own alert) skips this one.
    func pushAlert(title: String, body: String, unlessRevival: Bool = false) {
        guard configured else { return }
        for registration in registrations.values where registration.kind == .alert {
            if unlessRevival, showsRevival(device: registration.deviceId) { continue }
            send(LiveActivityPush.alertPayload(title: title, body: body), to: registration, what: "alert")
        }
    }

    private func showsRevival(device: String) -> Bool {
        hasLive(.revival, device: device)
            || registrations["\(device)/\(ActivityPushRegistration.Kind.revivalStart.rawValue)"] != nil
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

    private func send(_ payload: Data, to registration: ActivityPushRegistration, what: String) {
        let slot = registration.slot
        // Activity updates coalesce per slot; alerts are each their own
        // message (two in one refresh must both land).
        let key = registration.kind == .alert ? "\(slot)#\(UUID().uuidString)" : slot
        guard !inFlight.contains(key), let bearer = bearer() else { return }
        inFlight.insert(key)
        var request = URLRequest(url: LiveActivityPush.url(token: registration.token,
                                                           sandbox: registration.isSandbox),
                                 timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("bearer \(bearer)", forHTTPHeaderField: "authorization")
        let isAlert = registration.kind == .alert
        request.setValue(isAlert ? LiveActivityPush.bundleID : LiveActivityPush.topic,
                         forHTTPHeaderField: "apns-topic")
        request.setValue(isAlert ? "alert" : "liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
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
                } else {
                    let why = error?.localizedDescription ?? "HTTP \(code) \(body)"
                    self.lastResult = "\(what) → \(device) failed: \(why)"
                    self.log?("⚠️", "Live Activity push failed: \(why)")
                    // A dead token will never work again — drop it.
                    if LiveActivityPush.isDeadToken(status: code, body: body) {
                        self.registrations[slot] = nil
                        self.persist()
                    } else if body.contains("InvalidProviderToken") || body.contains("ExpiredProviderToken") {
                        self.jwt = nil
                    }
                }
            }
        }.resume()
    }
}
