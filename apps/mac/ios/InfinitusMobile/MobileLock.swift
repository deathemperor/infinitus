import Foundation
import LocalAuthentication

/// The phone's own biometric lock (spec §2.2): the Team tab, or since
/// #212 the whole app — on launch and on return from the background.
/// `.deviceOwnerAuthentication` so the passcode is the fallback the OS
/// itself offers. A fresh LAContext per prompt: a reused one answers
/// from its own cache.
@MainActor
final class MobileLock: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case off, team, app
        var id: String { rawValue }
    }

    static let shared = MobileLock()
    static let scopeKey = "lock_scope"
    /// The pre-#212 Team-tab switch: read once for the migration, left
    /// in place for rollback.
    static let legacyKey = "team_lock"

    @Published var scope: Scope {
        didSet {
            UserDefaults.standard.set(scope.rawValue, forKey: Self.scopeKey)
            // Team scope relocks a tab the user is not looking at; app
            // scope would throw the lock screen over Settings, so it
            // waits for the next background or launch.
            locked = scope == .team
        }
    }
    @Published private(set) var locked: Bool
    /// One prompt at a time: the auto-prompt on foreground and the
    /// Unlock button can both ask.
    private var prompting = false

    /// Whether the lock is on at all. Settable so the plain
    /// Team-tab switch still binds to it.
    var enabled: Bool {
        get { scope != .off }
        set { scope = newValue ? .team : .off }
    }

    init() {
        let defaults = UserDefaults.standard
        let scope = defaults.string(forKey: Self.scopeKey).flatMap(Scope.init(rawValue:))
            ?? (defaults.bool(forKey: Self.legacyKey) ? .team : .off)
        self.scope = scope
        locked = scope != .off
    }

    var methodName: String {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return "passcode" }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "passcode"
        }
    }

    func unlock() async -> Bool {
        guard enabled else { locked = false; return true }
        if prompting { return false }
        prompting = true
        defer { prompting = false }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // No passcode on the device, so nothing to check against.
            // The Team tab stays shut (the join rule wants a real lock);
            // the whole app must never be sealed with no way in.
            if scope == .app { locked = false; return true }
            return false
        }
        let reason = scope == .app ? "Unlock Infinitus" : "Show your team"
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { locked = false }
        return ok
    }

    func relock() { if enabled { locked = true } }
}
