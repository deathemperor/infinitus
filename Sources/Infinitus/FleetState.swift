import SwiftUI
import Combine
import InfinitusCore
import InfinitusUI

/// One fleet's live state (#8 multi-engine seam): the accounts one
/// engine holds for one provider, plus every per-row animation trigger
/// the popup keys on. `apply` carries the alive↔dead diff that used to
/// live inline in AppModel.refreshSnapshot — verbatim, so a cswap-only
/// Mac behaves exactly as before. Display prefs are the host's; actions
/// go to the engine and then ask the host for a fresh snapshot.
@MainActor
final class FleetState: ObservableObject, Identifiable {
    let id: String
    let engineID: String
    let provider: Provider
    let engine: any AccountEngine
    unowned let host: AppModel

    @Published var accounts: [Account] = []
    @Published var activeNumber: Int?
    @Published var nextCandidate: Int?
    @Published var nextRecovery: NextRecovery?
    @Published var liveSessions: LiveSessions?
    @Published var switchFlashTick = 0
    @Published var deathTicks: [Int: Int] = [:]
    @Published var dying: Set<Int> = []
    @Published var reviveTicks: [Int: Int] = [:]
    @Published var pendingSwitch: Int?
    /// Set once a real snapshot decoded — gates the "no accounts" card
    /// so it can't flash during the first refresh.
    @Published var snapshotLoaded = false
    /// The last applied snapshot, as the launch cache stores it.
    private(set) var lastFleet: EngineFleet?
    /// Cash column (UsageSource): the cswap fleet mirrors the shared
    /// UsageModel; other engines fill this from their own report.
    @Published var report: UsageReport?
    private var reportSink: AnyCancellable?
    private var hostSink: AnyCancellable?
    private var forwarding = false

    var capabilities: EngineCapabilities { engine.capabilities }

    init(fleet: EngineFleet, engine: any AccountEngine, host: AppModel) {
        id = fleet.key
        engineID = fleet.engineID
        provider = fleet.provider
        self.engine = engine
        self.host = host
        // Pref changes on the host must re-render rows that observe only
        // this object. Guarded: the host forwards our changes back up.
        hostSink = host.objectWillChange.sink { [weak self] _ in
            guard let self, !self.forwarding else { return }
            self.forwarding = true
            self.objectWillChange.send()
            self.forwarding = false
        }
    }

    /// Mirror another report source (the cswap fleet's shared UsageModel).
    func follow(_ usage: UsageModel) {
        report = usage.report
        reportSink = usage.$report.sink { [weak self] r in self?.report = r }
    }

    /// What one snapshot changed — the host runs its app-level hooks
    /// (notifications, resume, push) off this for the primary fleet.
    struct Change {
        let previousActive: Int?
        let firstLoad: Bool
        let changed: Bool
        let newlyDead: [Int]
        let newlyAlive: [Int]
    }

    /// Launch-cache seed: last run's rows render NOW, no animation, no
    /// ticks, snapshotLoaded stays false (same as the old cache path).
    func seed(_ fleet: EngineFleet) {
        accounts = fleet.accounts
        activeNumber = fleet.activeNumber
        nextCandidate = fleet.nextCandidate
        nextRecovery = RecoveryMath.corrected(engine: fleet.nextRecovery, accounts: fleet.accounts, activeNumber: fleet.activeNumber)
        liveSessions = fleet.liveSessions
        lastFleet = fleet
    }

    @discardableResult
    func apply(_ fleet: EngineFleet) -> Change {
        let list = fleet.accounts
        let previousActive = activeNumber
        // withAnimation: the pct texts carry .contentTransition(.numericText)
        // so a fresh snapshot rolls the digits (the token-burn feel)
        // instead of snapping them.
        let changed = !Self.visuallyEqual(accounts, list)
        let firstLoad = accounts.isEmpty && !list.isEmpty
        // alive -> dead diff BEFORE the state swap. First load has no
        // previous state, so nothing fires on launch by construction.
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
        if !snapshotLoaded { snapshotLoaded = true }
        lastFleet = fleet
        // Each @Published set synchronously re-runs every observer's body
        // (#18): assign only what actually differs. `accounts` nearly
        // always does (usage age, countdown strings) — that one render
        // per refresh is the price of live labels.
        withAnimation(.easeInOut(duration: 0.6)) {
            accounts = list
            if activeNumber != fleet.activeNumber { activeNumber = fleet.activeNumber }
            if nextCandidate != fleet.nextCandidate { nextCandidate = fleet.nextCandidate }
            let recovery = RecoveryMath.corrected(engine: fleet.nextRecovery, accounts: list, activeNumber: fleet.activeNumber)
            if nextRecovery != recovery { nextRecovery = recovery }
            if liveSessions != fleet.liveSessions { liveSessions = fleet.liveSessions }
        }
        if let now = fleet.activeNumber, let previousActive,
           previousActive != now {
            switchFlashTick += 1
        }
        // The death sequence (user 2026-08-31: kill animation for
        // the last drop of any kind, "still play dead animation
        // after"): the row keeps its gauges while the killing
        // drop plays (plunge 0-1.5s, shards+shake ~1.5-2.4s), the
        // death beat lands AFTER the finisher, and only then does
        // the layout flip to the dead presentation.
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
        return Change(previousActive: previousActive, firstLoad: firstLoad,
                      changed: changed, newlyDead: newlyDead, newlyAlive: newlyAlive)
    }

    /// "Did anything the popup RENDERS change?" — cheap positional
    /// comparison of the fields the rows show.
    static func visuallyEqual(_ a: [Account], _ b: [Account]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.number != y.number || x.active != y.active
                || x.alias != y.alias || x.disabled != y.disabled
                || x.usage?.fiveHour?.pct != y.usage?.fiveHour?.pct
                || x.usage?.sevenDay?.pct != y.usage?.sevenDay?.pct
                || x.usage?.spend?.pct != y.usage?.spend?.pct
                || (x.usage?.scoped ?? []).map(\.pct) != (y.usage?.scoped ?? []).map(\.pct) {
                return false
            }
        }
        return true
    }

    // MARK: actions — engine first, then a fresh snapshot

    private func perform(after settle: @escaping @MainActor () -> Void = {},
                         _ op: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await op()
                host.lastError = nil
            } catch { host.lastError = "\(error)" }
            await host.refreshSnapshot()
            settle()
        }
    }

    func switchTo(_ number: Int) {
        let engine = engine, provider = provider
        perform { try await engine.switchTo(fleet: provider, number: number) }
    }

    func rotate() {
        let engine = engine, provider = provider
        perform { try await engine.rotate(fleet: provider) }
    }

    /// Hold an account out of rotation / return it (engine-side flag;
    /// the row renders as "disabled" either way).
    func setRotation(_ number: Int, enabled: Bool) {
        let engine = engine, provider = provider
        perform { try await engine.setHold(fleet: provider, number: number, held: !enabled) }
    }

    /// Stars flipped but not yet confirmed by the engine (the subprocess
    /// plus the snapshot refresh take a few seconds — user 2026-09-03
    /// "pressing star … is not responsive"): the row shows this at once.
    @Published var pendingPreferred: [Int: Bool] = [:]

    /// Star/unstar through the engine's own pick-first knob. Starring
    /// also lands on the account right away when it isn't the active one
    /// (user 2026-09-03 "stared P3 but it doesn't … switch to it"): the
    /// knob only orders the engine's FUTURE switches, and a star reads as
    /// "use this one" — a one-shot switch, not a second policy.
    func setPreferred(_ number: Int, _ on: Bool) {
        let engine = engine, provider = provider
        let land = on && capabilities.contains(.switch)
            && !(accounts.first { $0.number == number }?.active ?? true)
        pendingPreferred[number] = on
        perform(after: { [weak self] in self?.pendingPreferred[number] = nil }) {
            try await engine.setPreferred(fleet: provider, number: number, on)
            if land { try await engine.switchTo(fleet: provider, number: number) }
        }
    }

    func remove(_ number: Int) {
        let engine = engine, provider = provider
        perform { try await engine.remove(fleet: provider, number: number) }
    }

    /// Write every managed account to `path`. The file holds CREDENTIALS,
    /// so the caller warns before offering it and this reports where it
    /// landed rather than a bare success.
    func exportAccounts(to path: URL, full: Bool, done: @escaping (String?) -> Void) {
        let engine = engine
        Task {
            do {
                try await engine.exportAccounts(to: path, account: nil, full: full)
                done(nil)
            } catch let error as CLIError {
                // The engine's own words ("no accounts to export …"),
                // which is what the user has to act on.
                done(error.message)
            } catch { done("\(error)") }
        }
    }

    /// Read accounts back. `force` REPLACES existing slots — the caller
    /// must have confirmed it. A successful import changes the fleet, so
    /// the snapshot is refreshed before the completion runs.
    func importAccounts(from path: URL, force: Bool, done: @escaping (String?) -> Void) {
        let engine = engine
        Task {
            do {
                try await engine.importAccounts(from: path, force: force)
                await host.refreshSnapshot()
                done(nil)
            } catch let error as CLIError {
                done(error.message)
            } catch { done("\(error)") }
        }
    }

    /// Every account gets a fresh name from the theme's pool, in one
    /// pass (user 2026-09-04 "randomize account names").
    func randomizeNames() {
        let engine = engine, provider = provider
        let names = rowTheme.randomAccountNames(count: accounts.count)
        let pairs = Array(zip(accounts.map(\.number), names))
        Task {
            do {
                for (number, name) in pairs {
                    try await engine.rename(fleet: provider, number: number, name)
                }
                host.reorderError = nil
            } catch { host.reorderError = "\(error)" }
            await host.refreshSnapshot()
        }
    }

    /// Rename = set/clear the account's alias, so every frontend
    /// (TUI, CLI, popup) shows the same name.
    func rename(_ number: Int, to name: String) {
        let engine = engine, provider = provider
        Task {
            do {
                try await engine.rename(fleet: provider, number: number, name)
                host.reorderError = nil
            } catch { host.reorderError = "\(error)" }
            await host.refreshSnapshot()
        }
    }

    /// Apply a drag-reorder: `order` is the account numbers in their new
    /// top-to-bottom sequence. Optimistically re-sorts the local rows so the
    /// row lands where it was dropped, then lets the snapshot confirm.
    func reorder(_ order: [Int], done: (() -> Void)? = nil) {
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        accounts.sort { (index[$0.number] ?? 0) < (index[$1.number] ?? 0) }
        let engine = engine, provider = provider
        Task {
            do {
                try await engine.reorder(fleet: provider, order)
                host.reorderError = nil
            } catch { host.reorderError = "\(error)" }
            await host.refreshSnapshot()
            done?()
        }
    }
}

/// The shared fleet views render off this; prefs and popup-wide state
/// are the host's, only the fleet's own rows/ticks live here.
extension FleetState: FleetModel {
    /// What the popup rows iterate: raw engine order, or the headroom
    /// sort with active + next pinned.
    var displayAccounts: [Account] {
        host.sortByHeadroom
            ? DisplayOrder.sort(accounts, active: activeNumber, next: nextCandidate)
            : accounts
    }
    var rowTheme: RowTheme { host.rowTheme }
    var compactRows: Bool { host.compactRows }
    var burnStyle: String { host.burnStyle }
    var popupLayout: String { host.popupLayout }
    var waitingResume: Int? { host.waitingResume }
    var fillScale: Double { host.fillScale }
    var isPlayground: Bool { host.isPlayground }
    var sessionsShown: Bool {
        get { host.sessionsShown }
        set { host.sessionsShown = newValue }
    }
    var engineBadge: EngineBadge? { host.engineBadge }
    var fleetLabel: FleetLabel? {
        FleetLabel(engineName: engine.displayName, provider: provider,
                   caveat: host.fleetCaveats[engineID])
    }
    var appUpdatePending: Bool { host.appUpdatePending }
    var appUpdateVersion: String? { host.appUpdateVersion }
    var engineMissing: Bool { host.engineMissing }
    var introTick: Int { host.introTick }
    var introStyle: String { host.introStyle }
    var introSpeed: Double { host.introSpeed }
    var introTitle: String { host.introTitle }
    var introBarDelay: Double { host.introBarDelay }

    /// cswap re-logins run the app's token flow; an OAuth engine (the
    /// proxy) signs in through the browser instead.
    func startRelogin(_ account: Account) {
        if engineID == CswapEngine.engineID { host.startRelogin(account) }
        else if capabilities.contains(.addOAuth) {
            host.addOAuthAccount(engineID: engineID, provider: provider, relogin: account)
        }
    }
    func toggleEngine() { host.toggleEngine() }
    func relaunchApp() { host.relaunchApp() }
    func openSettings() { host.openSettings() }
    /// A second account: cswap through the in-app token flow (a fresh
    /// login, not `cswap add` — that would re-adopt the same account),
    /// an OAuth engine through its browser sign-in.
    func addAccount() {
        if engineID == CswapEngine.engineID { host.addAccount() }
        else if capabilities.contains(.addOAuth) {
            host.addOAuthAccount(engineID: engineID, provider: provider)
        }
    }
    var canAddAccount: Bool {
        engineID == CswapEngine.engineID || capabilities.contains(.addOAuth)
    }
}

extension FleetState: UsageSource {
    func loadIfNeeded() {
        guard capabilities.contains(.costReport) else { return }
        if engineID == CswapEngine.engineID { return }   // the shared UsageModel drives it
        guard report == nil else { return }
        let engine = engine
        Task {
            if let r = try? await engine.usageReport(days: 7) {
                withAnimation(.easeInOut(duration: 0.3)) { self.report = r }
            }
        }
    }
}
