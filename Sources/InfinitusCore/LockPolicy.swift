import Foundation

/// The biometric lock as a value (spec §2.2): whether the setting is on,
/// whether the surfaces are locked right now, and when they re-lock.
/// Pure — no timer, no clock. Every event takes `now` in unix seconds and
/// the app feeds it the moments that matter (a surface shows or hides, a
/// window becomes key, the Mac sleeps or wakes), so an armed re-lock costs
/// nothing while idle and is settled on the next interaction. Carries no
/// key material: re-locking hides views, and the team working key stays
/// wherever it lives (TeamClient).
///
/// Re-lock modes:
///   .immediately  locks when a surface hides (the pop-out closes, Settings
///                 closes) and on sleep; time never enters into it.
///   .fiveMinutes / .oneHour  lock once `now - lastActivity >= seconds`;
///                 activity = an unlock, a surface showing, a window
///                 becoming key. Sleep alone doesn't lock; the wake tick
///                 does when the window has passed.
///   .onSleep      locks on sleep only.
/// The same policy runs on every platform that has a lock; on Linux
/// nothing constructs one until the passphrase lock ships.
public struct LockPolicy: Equatable, Sendable {
    public enum Relock: Int, CaseIterable, Sendable {
        case immediately = 0
        case fiveMinutes = 300
        case oneHour = 3600
        case onSleep = -1

        public static let `default` = Relock.oneHour

        /// The short form `lock-status` reports.
        public var label: String {
            switch self {
            case .immediately: return "immediately"
            case .fiveMinutes: return "5 min"
            case .oneHour: return "1 h"
            case .onSleep: return "on sleep"
            }
        }
    }

    public private(set) var enabled: Bool
    public var relock: Relock
    public private(set) var locked: Bool
    /// Unix seconds of the last unlock or interaction while unlocked;
    /// nil whenever locked or off.
    public private(set) var lastActivity: Int?

    public init(enabled: Bool = false, relock: Relock = .default) {
        self.enabled = enabled
        self.relock = relock
        self.locked = enabled
        self.lastActivity = nil
    }

    /// What the surfaces check: on and locked.
    public var needsUnlock: Bool { enabled && locked }

    /// Turning it on locks until the first unlock; turning it off clears.
    public mutating func setEnabled(_ on: Bool) {
        enabled = on
        locked = on
        lastActivity = nil
    }

    public mutating func unlocked(at now: Int) {
        guard enabled else { return }
        locked = false
        lastActivity = now
    }

    public mutating func lock() {
        if enabled { locked = true }
        lastActivity = nil
    }

    /// Settle a timed re-lock: locks when the interval since the last
    /// activity has passed. Cheap; called on every interaction and wake.
    public mutating func tick(at now: Int) {
        guard enabled, !locked, relock.rawValue > 0,
              let last = lastActivity, now - last >= relock.rawValue else { return }
        locked = true
        lastActivity = nil
    }

    /// An interaction: settle first, then extend the window if still open.
    public mutating func activity(at now: Int) {
        tick(at: now)
        if enabled, !locked { lastActivity = now }
    }

    /// A surface went away (pop-out closed, Settings closed).
    public mutating func hidden() {
        if relock == .immediately { lock() }
    }

    public mutating func sleep() {
        if relock == .onSleep || relock == .immediately { lock() }
    }

    public mutating func wake(at now: Int) {
        tick(at: now)
    }
}

/// Where the setting lives and how other processes read it.
public enum LockSetting {
    /// UserDefaults keys (the Mac app's prefs domain; the phone's own
    /// switch is plan 8). Bool, default false; Int seconds per
    /// `LockPolicy.Relock.rawValue`, default 3600.
    public static let enabledKey = "biometric_lock"
    public static let relockKey = "biometric_relock"

    public static func enabled(stored: Any?) -> Bool {
        stored as? Bool ?? false
    }

    public static func relock(stored: Any?) -> LockPolicy.Relock {
        (stored as? Int).flatMap(LockPolicy.Relock.init(rawValue:)) ?? .default
    }
}
