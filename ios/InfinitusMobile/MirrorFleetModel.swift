import SwiftUI
import InfinitusCore
import InfinitusUI

/// One engine fleet's live state, mirrored from the Mac's `EngineFleet`
/// (#9 issue 9: one section per fleet). Owns the rows and every per-row
/// animation trigger — `apply` is the Mac's `FleetState.apply` diff,
/// verbatim, so a cswap-only phone behaves exactly as before. Popup-wide
/// state (theme, prefs, sessions-card visibility, footer chips) stays on
/// the coordinating `MirrorModel`, read through `host` — same split as
/// the Mac's `FleetState` / `AppModel`.
@MainActor
final class MirrorFleetModel: ObservableObject, Identifiable {
    let id: String
    let engineID: String
    let provider: Provider
    unowned let host: MirrorModel
    /// False for another paired Mac's fleet (#144 phase 1): the mirror
    /// only ever carries the PRIMARY's `usageJSON`, so a fleet that isn't
    /// the primary's must not borrow it under a coincidentally-matching
    /// account number.
    let hostUsage: Bool

    @Published private(set) var accounts: [Account] = []
    @Published private(set) var activeNumber: Int?
    @Published private(set) var nextCandidate: Int?
    @Published private(set) var nextRecovery: NextRecovery?
    @Published private(set) var liveSessions: LiveSessions?
    /// What the Mac's engine can do to these accounts (nil from an older
    /// Mac): gates the row's star/pause actions.
    @Published private(set) var capabilities: EngineCapabilities?
    @Published private(set) var switchFlashTick = 0
    @Published private(set) var deathTicks: [Int: Int] = [:]
    @Published private(set) var dying: Set<Int> = []
    @Published private(set) var reviveTicks: [Int: Int] = [:]
    /// The cash column's source: filled synchronously from the snapshot's
    /// `usageJSON`, cswap-only (the mirror carries only cswap's cache).
    @Published private(set) var report: UsageReport?
    private var usageCapturedAt: Date?

    init(engineID: String, provider: Provider, host: MirrorModel, hostUsage: Bool = true) {
        // EngineRegistry's key: an engine may yield one fleet per provider.
        self.id = "\(engineID)/\(provider.rawValue)"
        self.engineID = engineID
        self.provider = provider
        self.host = host
        self.hostUsage = hostUsage
    }

    /// The intro replay's celebration beat (MirrorModel.replayIntro) —
    /// kept a method, not a settable property, so nothing outside the
    /// diff/intro sequence can drive it.
    func bumpSwitchFlash() { switchFlashTick += 1 }

    /// What one snapshot changed — the host uses `firstLoad` to decide
    /// whether to replay the intro (only the primary fleet's counts).
    struct Change {
        let firstLoad: Bool
    }

    /// `FleetState.apply`'s diff, unchanged: the alive/dead comparison
    /// happens BEFORE the state swap (first load fires nothing by
    /// construction), and the swap is animated so the pct texts'
    /// `.contentTransition(.numericText)` rolls its digits.
    @discardableResult
    func apply(_ fleet: EngineFleet) -> Change {
        let list = fleet.accounts
        let previousActive = activeNumber
        let firstLoad = accounts.isEmpty && !list.isEmpty
        let wasAlive = Set(accounts.filter {
            !AccountVitals.isDead($0.usage) }.map(\.number))
        let newlyDead = list.filter {
            AccountVitals.isDead($0.usage) && wasAlive.contains($0.number)
        }.map(\.number)
        let wasDead = Set(accounts.filter {
            AccountVitals.isDead($0.usage) }.map(\.number))
        let newlyAlive = list.filter {
            !AccountVitals.isDead($0.usage) && wasDead.contains($0.number)
        }.map(\.number)
        withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.6)) {
            accounts = list
            activeNumber = fleet.activeNumber
            nextCandidate = fleet.nextCandidate
            nextRecovery = RecoveryMath.corrected(engine: fleet.nextRecovery, accounts: list, activeNumber: fleet.activeNumber)
            liveSessions = fleet.liveSessions
        }
        capabilities = fleet.capabilities
        if let now = fleet.activeNumber, let previousActive,
           previousActive != now {
            switchFlashTick += 1
        }
        // The death sequence: the row keeps its gauges while the killing
        // drop plays, the death beat lands after the finisher, and only
        // then does the dead presentation take over.
        for n in newlyDead {
            dying.insert(n)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                self.deathTicks[n, default: 0] += 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.9) {
                self.dying.remove(n)
            }
        }
        for n in newlyAlive { reviveTicks[n, default: 0] += 1 }
        return Change(firstLoad: firstLoad)
    }

    /// `CswapEngine.engineID` itself is `#if !os(iOS)` (the engine spawns
    /// a subprocess) — the phone only ever sees its id string, mirrored
    /// verbatim from the Mac's `EngineFleet.engineID`.
    static let cswapEngineID = "cswap"

    /// Same mapping the Mac's `FleetState.fleetLabel` reads off its
    /// `engine.displayName` — the phone has no `AccountEngine` instance
    /// to ask, so it names the two engines it actually mirrors and
    /// falls back to the raw id for anything else.
    static func engineName(for engineID: String) -> String {
        switch engineID {
        case cswapEngineID: return "cswap"
        case CLIProxyEngine.engineID: return "CLIProxyAPI"
        default: return engineID
        }
    }
}

extension MirrorFleetModel: FleetModel {
    /// What the rows iterate: the headroom sort with active + next
    /// pinned, unless Follow Mac carries a mirrored `sortByHeadroom ==
    /// false` — same rule as before, now read off the shared host.
    var displayAccounts: [Account] {
        host.sortByHeadroom
            ? DisplayOrder.sort(accounts, active: activeNumber, next: nextCandidate)
            : accounts
    }
    var rowTheme: RowTheme { host.rowTheme }
    var compactRows: Bool { host.compactRows }
    var reviveLead: TimeInterval { host.reviveLead }
    var burnStyle: String { host.burnStyle }
    var popupLayout: String { host.popupLayout }
    /// A row tap stages a switch on the mac, where an alert commits it.
    /// The phone can't drive the engine, so the staged number is dropped
    /// the moment it's set.
    var pendingSwitch: Int? {
        get { nil }
        set { _ = newValue }
    }
    var fillScale: Double { host.fillScale }
    var isPlayground: Bool { host.isPlayground }
    /// The card is rendered inline on the phone, so the chip's flag
    /// never goes up.
    var sessionsShown: Bool {
        get { false }
        set { _ = newValue }
    }
    var engineBadge: EngineBadge? { host.engineBadge }
    var fleetLabel: FleetLabel? {
        FleetLabel(engineName: Self.engineName(for: engineID), provider: provider)
    }
    var engineMissing: Bool { false }
    var snapshotLoaded: Bool { host.snapshotLoaded }
    var introTick: Int { host.introTick }
    var introStyle: String { host.introStyle }
    var introSpeed: Double { host.introSpeed }
    var introTitle: String { host.introTitle }
    var introBarDelay: Double { host.introBarDelay }
}

extension MirrorModel {
    /// The mirrored fleets, reconstituted as plain `EngineFleet`s — same
    /// fields `MirrorFleetModel.apply` keeps published — for
    /// `SessionAccountLookup`, which stays a pure Core function with no
    /// notion of the phone's `ObservableObject` wrapper.
    var engineFleets: [EngineFleet] {
        fleets.map {
            EngineFleet(engineID: $0.engineID, provider: $0.provider, accounts: $0.accounts,
                        activeNumber: $0.activeNumber, nextCandidate: $0.nextCandidate,
                        nextRecovery: $0.nextRecovery, liveSessions: $0.liveSessions,
                        capabilities: $0.capabilities)
        }
    }

    /// Which account (cswap) or fleet (CLIProxyAPI's per-request routing)
    /// is actually serving a live session ("which account is active or
    /// using the session", user 2026-09-03).
    func accountSummary(forSessionPid pid: Int) -> SessionAccountSummary? {
        SessionAccountLookup.summarize(pid: pid, fleets: engineFleets)
    }
}

extension MirrorFleetModel: UsageSource {
    /// Same fidelity as the Mac popup's cash column here: only cswap's
    /// report ever rides the mirror (`MirrorSnapshot.usageJSON`), so
    /// every other engine's fleet simply keeps empty cells.
    func loadIfNeeded() {
        guard hostUsage, engineID == Self.cswapEngineID else { return }
        guard let snapshot = host.snapshot, snapshot.capturedAt != usageCapturedAt,
              let data = snapshot.usageJSON else { return }
        usageCapturedAt = snapshot.capturedAt
        report = try? JSONDecoder().decode(UsageReport.self, from: data)
    }
}
