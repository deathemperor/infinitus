import AppKit
import SwiftUI
import InfinitusCore

/// The app's lock (spec §2.2): `LockPolicy` is the state machine, this
/// wraps it as an ObservableObject, persists the two settings, feeds it
/// sleep and wake, and runs the LocalAuthentication prompt. No timers: a
/// timed re-lock is settled when a surface shows, a window becomes key or
/// the Mac wakes (StatusItemController feeds those), so the pop-out idles
/// at 0% locked or not. Holds no key material: re-locking swaps views.
@MainActor
final class LockModel: ObservableObject {
    /// The Settings tab's title — `revealSetting()` selects it by name.
    static let paneTitle = "Lock"

    @Published private(set) var policy: LockPolicy
    /// The last prompt's failure, shown under the Unlock button; cleared
    /// on the next attempt. A cancel leaves it nil.
    @Published private(set) var lastError: String?
    /// Set by StatusItemHolder: opens the Settings window (the "button to
    /// the setting" a disabled team action offers, plan 5).
    var showSettings: (() -> Void)?
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        policy = LockPolicy(enabled: LockSetting.enabled(stored: defaults.object(forKey: LockSetting.enabledKey)),
                            relock: LockSetting.relock(stored: defaults.object(forKey: LockSetting.relockKey)))
        // Sleep/wake come from the workspace center, not NotificationCenter.default.
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mutate { $0.sleep() } }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mutate { $0.wake(at: Self.now()) } }
            },
        ]
    }

    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    var enabled: Bool { policy.enabled }

    var relock: LockPolicy.Relock {
        get { policy.relock }
        set {
            mutate { $0.relock = newValue }
            defaults.set(newValue.rawValue, forKey: LockSetting.relockKey)
        }
    }

    /// Every policy change lands through here, animated: the pop-out
    /// panels follow their content's measured size (fitAnchored /
    /// fitPinned), and an animated swap glides instead of snapping.
    private func mutate(_ change: (inout LockPolicy) -> Void) {
        var next = policy
        change(&next)
        guard next != policy else { return }
        withAnimation(.easeInOut(duration: 0.25)) { policy = next }
    }

    // MARK: events from the surfaces (StatusItemController)

    /// A surface showed or a window became key: settle a timed re-lock,
    /// then count the interaction.
    func surfaceShown() { mutate { $0.activity(at: Self.now()) } }
    /// The pop-out or Settings closed.
    func surfaceHidden() { mutate { $0.hidden() } }
    func lockNow() { mutate { $0.lock() } }

    // MARK: the prompt

    func unlock() async {
        lastError = nil
        switch await BiometricLock.authenticate(reason: "unlock Infinitus") {
        case .ok: mutate { $0.unlocked(at: Self.now()) }
        case .cancelled: break
        case .failed(let why): lastError = why
        }
    }

    /// One prompt proves the method works before anything is locked
    /// behind it; success leaves the surfaces unlocked so the Settings
    /// window the user is standing in stays put. False = still off.
    func turnOn() async -> Bool {
        lastError = nil
        switch await BiometricLock.authenticate(reason: "turn on biometric unlock") {
        case .ok:
            mutate { $0.setEnabled(true); $0.unlocked(at: Self.now()) }
            defaults.set(true, forKey: LockSetting.enabledKey)
            return true
        case .cancelled:
            return false
        case .failed(let why):
            lastError = why
            return false
        }
    }

    /// Allowed while in a team (the pane warns first); the app never
    /// leaves a team by itself.
    func turnOff() {
        mutate { $0.setEnabled(false) }
        defaults.set(false, forKey: LockSetting.enabledKey)
    }

    // MARK: teams

    /// Names of the teams this Mac is in — for the off-while-in-a-team
    /// warning. Reads the config files only (never TeamClient.open, which
    /// spawns git); called on the toggle, not per render.
    func teamNames() -> [String] {
        let paths = TeamPaths.standard()
        return paths.teamIDs().compactMap { id in
            (try? Data(contentsOf: paths.configFile(id)))
                .flatMap { try? CanonicalJSON.decode(TeamConfig.self, from: $0) }?.name
        }
    }

    /// Opens Settings on the Lock pane. The pane's `onReceive` subscribes
    /// on its first body evaluation, so the selection posts one turn later.
    func revealSetting() {
        showSettings?()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("infinitus.selectPane"),
                                            object: LockModel.paneTitle)
        }
    }
}
