import SwiftUI
import InfinitusCore

/// What the fleet rows/cards read from their host's model (#9 phase B).
/// The mac app's AppModel conforms; the phone app has its own store —
/// the VIEWS stay one copy, so the popup renders pixel-identically on
/// both (that's the whole point of the shared target).
///
/// Exactly the members the moved views touch, nothing speculative: add
/// one only when a view actually reads it.
@MainActor
public protocol FleetModel: ObservableObject {
    var accounts: [Account] { get }
    /// What the rows iterate — engine order or the headroom sort.
    var displayAccounts: [Account] { get }
    var rowTheme: RowTheme { get }
    var compactRows: Bool { get }
    var burnStyle: String { get }
    var popupLayout: String { get }
    var nextCandidate: Int? { get }
    var nextRecovery: NextRecovery? { get }
    /// Limit-stopped sessions the resume nudge is holding — the all-dead
    /// banner's suffix.
    var waitingResume: Int? { get }
    /// Set by a row click; the host puts up its own confirmation.
    var pendingSwitch: Int? { get set }
    var switchFlashTick: Int { get }
    var reviveTicks: [Int: Int] { get }
    var deathTicks: [Int: Int] { get }
    var dying: Set<Int> { get }
    var fillScale: Double { get }
    var isPlayground: Bool { get }

    // Footer chips (#9 phase D2) — what FooterChips reads.
    /// Live Claude Code sessions on the host's machine (the brain chip).
    var liveSessions: LiveSessions? { get }
    /// The sessions card's presentation flag; a host that shows the card
    /// some other way (the phone renders it inline) keeps it false.
    var sessionsShown: Bool { get set }
    /// The auto-switch engine's badge state — nil on a host that has no
    /// engine reading to show.
    var engineBadge: EngineBadge? { get }
    /// Multi-engine (#8): what this fleet's engine can do — rows hide
    /// the affordances it can't. A single-engine host keeps `.all`.
    var capabilities: EngineCapabilities { get }
    /// Multi-engine (#8): the section header when several fleets stack;
    /// nil on a host that shows one fleet.
    var fleetLabel: FleetLabel? { get }
    /// Update chips: a newer build on disk / a newer release upstream.
    var appUpdatePending: Bool { get }
    var appUpdateVersion: String? { get }
    /// #7: the reset battle plan the planner proposes right now; nil when
    /// nothing is worth planning. The card rides the error slot.
    var battlePlan: WindowPlanner.Plan? { get }
    /// The account an ignition is in flight for (button shows a spinner).
    var igniting: Int? { get }
    /// Whether this host's engine can ignite (capability `.ignite`); the
    /// button is hidden otherwise — the plan line still shows.
    var canIgnite: Bool { get }
    /// Run-rate projection (when each window of the active account hits
    /// its limit, when the fleet is out); nil on a host without one.
    var forecast: UsageForecast? { get }
    /// AWS sign-ins sessions are waiting on (AwsLogin.swift); the popup
    /// line offers this host's own browser flow.
    var awsLogins: [AwsLogin.Item] { get }
    func startAwsLogin(profile: String, pid: Int?, local: Bool)
    /// Open the full forecast (the Mac's Utilization pane, the phone's
    /// Outlook screen) — the "at this pace" line is a link to it.
    func openForecast()

    // Intro choreography (Animations.swift) — the entrance gates.
    var engineMissing: Bool { get }
    var snapshotLoaded: Bool { get }
    var introTick: Int { get }
    var introStyle: String { get }
    var introSpeed: Double { get }
    var introTitle: String { get }
    var introBarDelay: Double { get }

    /// The one row ACTION beyond pendingSwitch: relogin_required starts
    /// the host's OAuth flow (mac-only; the phone can't drive it).
    func startRelogin(_ account: Account)
    /// Footer-chip actions — all mac-only, all no-ops on a host that
    /// only mirrors (same shape as startRelogin).
    func toggleEngine()
    func relaunchApp()
    func openSettings()
    /// #7 manual mode: start account n's 5h clock (`cswap run` igniter).
    /// Mac-only; the card confirm-gates it.
    func ignite(_ number: Int)
    /// The solo card's nudge: open this fleet's sign-in for a second
    /// account. Mac-only; a mirroring host leaves it a no-op and the
    /// card hides the button.
    func addAccount()
    var canAddAccount: Bool { get }
    /// A row's context menu: star/unstar (the engine's pick-first knob)
    /// and pause/resume (hold out of rotation) — the Settings › Accounts
    /// buttons, reachable from the popup. Mac-only; a mirroring host
    /// leaves them no-ops.
    func setPreferred(_ number: Int, _ on: Bool)
    func setRotation(_ number: Int, enabled: Bool)
}

/// One fleet's header line in a multi-fleet popup.
public struct FleetLabel: Sendable, Equatable {
    public let engineName: String
    public let provider: Provider
    /// Engine-side honesty note ("round-robin ignores priority tiers").
    public let caveat: String?
    public init(engineName: String, provider: Provider, caveat: String? = nil) {
        self.engineName = engineName
        self.provider = provider
        self.caveat = caveat
    }
}

public extension FleetModel {
    var capabilities: EngineCapabilities { .all }
    var fleetLabel: FleetLabel? { nil }
    func startRelogin(_ account: Account) {}
    func toggleEngine() {}
    func relaunchApp() {}
    func openSettings() {}
    var engineBadge: EngineBadge? { nil }
    var appUpdatePending: Bool { false }
    var appUpdateVersion: String? { nil }
    var battlePlan: WindowPlanner.Plan? { nil }
    var igniting: Int? { nil }
    var canIgnite: Bool { false }
    var forecast: UsageForecast? { nil }
    var awsLogins: [AwsLogin.Item] { [] }
    func startAwsLogin(profile: String, pid: Int?, local: Bool) {}
    func openForecast() {}
    func ignite(_ number: Int) {}
    func addAccount() {}
    var canAddAccount: Bool { false }
    func setPreferred(_ number: Int, _ on: Bool) {}
    func setRotation(_ number: Int, enabled: Bool) {}
    /// A host with no resume nudge (the phone) simply has no count —
    /// the banner then drops its suffix.
    var waitingResume: Int? { nil }
}

/// The cash column's source — the estimated-spend report the mac app
/// scans in the background. A host without one gets empty cells.
@MainActor
public protocol UsageSource: ObservableObject {
    var report: UsageReport? { get }
    func loadIfNeeded()
}

public extension UsageSource {
    func loadIfNeeded() {}
}
