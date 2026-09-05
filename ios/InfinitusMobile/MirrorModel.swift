import Foundation
import SwiftUI
import Combine
import InfinitusCore
import InfinitusUI

/// Reads the fleet mirror a Mac already captured (#9 phase 1's
/// `FleetMirror` seam) and republishes it as view-ready state.
///
/// Coordinates one `MirrorFleetModel` per `EngineFleet` of every paired
/// host (windows plan 04-phone), stable instances keyed by host + engine
/// across refreshes —
/// same split as the Mac's `EngineRegistry` / `FleetState`. Also
/// conforms to `FleetModel` itself (#9 phase C2), as a FACADE over the
/// primary (first Claude) fleet — same shape as the Mac's `AppModel` —
/// so the shared single-fleet views (header, all-dead banner, footer
/// chips) keep reading `model` directly on the "Show as Mac popup" view.
@MainActor
final class MirrorModel: ObservableObject, FleetModel {
    /// The one instance the app runs on — the scene's StateObject and
    /// the background-refresh task share it, so a refresh from either
    /// side lands in the same fleets and Live Activities.
    static let shared = MirrorModel()

    /// Every host's last snapshot, keyed by `MirrorHost.id` — the merged
    /// sessions list reads the whole map; the facade reads the primary
    /// host's, kept in `snapshot` for the pre-multi-host readers.
    @Published private(set) var snapshots: [String: MirrorSnapshot] = [:]
    /// The PRIMARY host's snapshot (the Mac): forecast, plan, footer
    /// chips and Live Activities all read this one.
    @Published private(set) var snapshot: MirrorSnapshot?
    /// Sessions waiting for an AWS sign-in (AwsLoginScreen), every host
    /// merged in stored order — a Windows daemon reports none, so this
    /// is the Mac's today.
    var awsLogins: [AwsLogin.Item] {
        hosts.compactMap { snapshots[$0.id]?.awsLogins }.flatMap { $0 }
    }
    func awsLogin(for pid: Int) -> AwsLogin.Item? {
        awsLogins.first { $0.pid == pid }
    }
    /// The Stats tab's four-period bundle, verbatim from the snapshot
    /// (2026-09-04); `nil` for snapshots captured before this field
    /// existed, or before the Mac's first scan finished.
    var stats: Stats.Bundle? { snapshot?.stats }
    /// One engine's fleet per element, in the Mac's popup order.
    @Published private(set) var fleets: [MirrorFleetModel] = []
    private var fleetSinks: [String: AnyCancellable] = [:]
    @Published private(set) var error: String?
    /// The Mac's display prefs (#9 phase C1: "Follow Mac"); `nil` for
    /// snapshots captured before this field existed.
    @Published private(set) var prefs: FleetPrefs?

    @Published private(set) var introTick = 0
    /// Set by the view from its geometry — portrait renders the mac's
    /// stacked cards, landscape its wide grid (user's fidelity rule).
    @Published var isLandscape = false

    /// The sessions card's progress feed, filled from the snapshot.
    let sessionProgress = MobileSessionProgress()

    private let mirror: FleetMirror
    private let defaults: UserDefaults
    /// Whether the LAN transport is in play (it isn't when the simulator
    /// is pointed at a file with INFINITUS_MIRROR_PATH, or at a fixture
    /// host list with INFINITUS_MIRROR_PATHS).
    private let usesLAN: Bool

    /// A dev-seam override, with an empty value read as unset — a shell
    /// exports a variable empty more often than it unsets it.
    private static func envValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return (value?.isEmpty == false) ? value : nil
    }

    // MARK: display prefs — Follow Mac, or local overrides

    /// Default ON: the phone is a mirror first (#9 phase C1).
    @Published var followMac: Bool {
        didSet {
            defaults.set(followMac, forKey: "follow_mac")
            AppIcons.follow(themeID: rowTheme.id)
        }
    }
    @Published var localThemeID: String {
        didSet {
            defaults.set(localThemeID, forKey: "gamification_style")
            AppIcons.follow(themeID: rowTheme.id)
        }
    }
    @Published var localCompactRows: Bool { didSet { defaults.set(localCompactRows, forKey: "compact_rows") } }
    @Published var localBurnStyle: String { didSet { defaults.set(localBurnStyle, forKey: "burn_style") } }
    @Published var localIntroStyle: String { didSet { defaults.set(localIntroStyle, forKey: "intro_style") } }
    @Published var localIntroTitle: String { didSet { defaults.set(localIntroTitle, forKey: "intro_title") } }
    @Published var localIntroSpeed: Double { didSet { defaults.set(localIntroSpeed, forKey: "intro_speed") } }
    /// "Show as Mac popup" (#9 native shell): the 1:1 rendering is kept,
    /// one toggle away — the native tab shell is the default.
    @Published var macPopupView: Bool { didSet { defaults.set(macPopupView, forKey: "mac_popup_view") } }

    // MARK: LAN transport (#9, one host per record since the windows plan)

    /// Every paired host, in stored order — the Mac first (host #0, the
    /// migrated record). The transport reads the same store straight
    /// from UserDefaults (#9 pair once, every route), so an edit takes
    /// effect at once either way.
    @Published private(set) var hosts: [MirrorHost] = []
    /// What the Settings screen shows about each connection.
    @Published private(set) var transportStatuses: [String: String] = [:]
    /// Pre-multi-host readers (Settings' connection section, the session
    /// detail's status line): the primary host's line, else the first
    /// host that has one.
    var transportStatus: String {
        if let id = primaryHostID, let line = transportStatuses[id] { return line }
        return hosts.compactMap { transportStatuses[$0.id] }.first ?? ""
    }

    /// Host #0's face, for the two fields Settings still binds (W14's
    /// Hosts section replaces them): the Mac's route list and its token.
    var manualEndpoints: [String] {
        get { hosts.first?.endpoints ?? [] }
        set { updateFirstHost { $0.endpoints = newValue } }
    }
    /// The Mac's pairing token: without it every request comes back 401,
    /// however the host was found.
    var pairToken: String {
        get { hosts.first?.token ?? "" }
        set {
            // What's stored is always the normalised token, so a token
            // typed with lowercase or dashes still matches.
            updateFirstHost { $0.token = MirrorPairing.normalize(newValue) }
        }
    }

    /// Writes host #0 through the store and reloads, so the transport
    /// sees the change on its very next fetch. Fixture hosts aren't in
    /// the store — nothing to update there.
    private func updateFirstHost(_ change: (inout MirrorHost) -> Void) {
        guard usesLAN, let first = hosts.first else { return }
        MirrorHostStore.update(first.id, defaults, change)
        hosts = MirrorHostStore.load(defaults)
        // The share extension (#64) reads the pairing through the
        // keychain — an edited route list or token must reach it.
        ShareBridge.publish(host: hosts.first, defaults)
    }

    /// The host the facade reads — the one `primary` came from.
    var primaryHostID: String? { primary?.hostID }

    init(mirror: FleetMirror? = nil, defaults: UserDefaults = .standard) {
        self.mirror = mirror ?? Self.makeMirror()
        self.defaults = defaults
        usesLAN = mirror == nil && Self.envValue("INFINITUS_MIRROR_PATH") == nil
            && Self.envValue("INFINITUS_MIRROR_PATHS") == nil
        if usesLAN {
            hosts = MirrorHostStore.load(defaults)   // runs the legacy migration
        } else if let spec = Self.envValue("INFINITUS_MIRROR_PATHS") {
            hosts = MirrorHostStore.fixtureHosts(spec).map { $0.host }
        }
        followMac = defaults.object(forKey: "follow_mac") as? Bool ?? true
        localThemeID = defaults.string(forKey: "gamification_style") ?? "off"
        localCompactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        localBurnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        localIntroStyle = defaults.string(forKey: "intro_style") ?? "top"
        localIntroTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        localIntroSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        macPopupView = defaults.object(forKey: "mac_popup_view") as? Bool ?? false
    }

    /// Pairs with a machine from a scanned QR or an `infinitus://pair?…`
    /// deep link. Multi-host rule (windows plan README): the same token
    /// is the same machine — every route the QR carries replaces that
    /// host's list (#9 pair once, every route) — any other token is a
    /// NEW host appended to the list, so a scan never unpairs the Mac.
    /// Returns the paired host, or nil for anything that isn't one of our pair URLs.
    @discardableResult
    func applyPairing(_ text: String) -> MirrorHost? {
        guard let pairing = MirrorPairing.parsePairURL(text) else { return nil }
        let paired = MirrorHostStore.upsert(endpoints: pairing.endpoints,
                                            token: pairing.token, defaults)
        if usesLAN {
            hosts = MirrorHostStore.load(defaults)
        } else if !hosts.contains(where: { $0.id == paired.id }) {
            hosts.append(paired)   // fixture mode: a host the store doesn't hold
        }
        Task { await refresh() }
        return paired
    }

    /// Adds an endpoint typed into Settings, de-duplicated — the field
    /// grows the list rather than replacing it (#9 pair once, every
    /// route: a phone paired on Wi-Fi can add a tunnel URL beside it).
    func addManualEndpoint(_ text: String) {
        let endpoint = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !manualEndpoints.contains(endpoint) else { return }
        manualEndpoints.append(endpoint)
    }

    func removeManualEndpoint(at offsets: IndexSet) {
        manualEndpoints.remove(atOffsets: offsets)
    }

    /// Swipe-to-delete in the Hosts section (W14's screen): dropping a
    /// host's record drops its token with it — that IS the revoke.
    func removeHost(at offsets: IndexSet) {
        guard usesLAN else { return }
        var stored = MirrorHostStore.load(defaults)
        stored.remove(atOffsets: offsets)
        MirrorHostStore.save(stored, defaults)
        hosts = stored
    }

    /// Delete a single host by its id.
    func removeHost(id: String) {
        guard usesLAN else { return }
        var stored = MirrorHostStore.load(defaults)
        stored.removeAll { $0.id == id }
        MirrorHostStore.save(stored, defaults)
        hosts = stored
    }

    /// Update a host's properties in the store and reload.
    func updateHost(_ id: String, _ change: (inout MirrorHost) -> Void) {
        guard usesLAN else { return }
        MirrorHostStore.update(id, defaults, change)
        hosts = MirrorHostStore.load(defaults)
    }

    /// `INFINITUS_MIRROR_PATH` lets a simulator point at one machine's
    /// live export, `INFINITUS_MIRROR_PATHS` at a colon-separated list
    /// of fixture snapshots (one per host — see `MirrorHostStore`);
    /// otherwise the LAN transport (#9) fetches from every paired host,
    /// with the app's own Documents copy as the offline fallback.
    /// `fileprivate`, not `private`: `MobileUsage` below reuses it to read
    /// the same snapshot independently (#9 phase D1a).
    fileprivate static func makeMirror() -> FleetMirror {
        if let paths = envValue("INFINITUS_MIRROR_PATHS") {
            let files = MirrorHostStore.fixturePaths(paths).map {
                FileFleetMirror(url: URL(fileURLWithPath: $0))
            }
            if !files.isEmpty { return ChainFleetMirror(mirrors: files) }
        }
        if let path = envValue("INFINITUS_MIRROR_PATH") {
            return FileFleetMirror(url: URL(fileURLWithPath: path))
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ChainFleetMirror(mirrors: [
            NetworkFleetMirror.shared,
            FileFleetMirror(url: documents.appendingPathComponent("mirror-snapshot.json")),
        ])
    }

    /// Pure decode of the mirror's `listJSON` payload — same `AccountList`
    /// model the mac app and tray decode, plain `JSONDecoder` (no date
    /// strategy; the model's date-bearing fields are raw ISO strings).
    static func decodeList(_ data: Data) -> AccountList? {
        try? JSONDecoder().decode(AccountList.self, from: data)
    }

    func refresh() async {
        do {
            if usesLAN {
                await refreshHosts()
            } else {
                try await refreshFile()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// The multi-host fan-out (04-phone): every paired host is asked at
    /// once, and each one's fleets join the merge in stored order — a
    /// dead host costs its own 3 s and degrades only its own section.
    private func refreshHosts() async {
        let answered = await NetworkFleetMirror.shared.latestAll(hosts)
        // The transport is the store's other writer (a swapped
        // quick-tunnel URL, a new last-good endpoint) — re-read rather
        // than second-guess it.
        hosts = MirrorHostStore.load(defaults)
        transportStatuses = await NetworkFleetMirror.shared.statuses
        var perHost: [(hostID: String, fleets: [EngineFleet])] = []
        var progress: [(hostID: String, byPid: [Int: SessionProgress])] = []
        var rates: [String: TokenRate] = [:]
        var decodeFailure: String?
        var liveIDs: Set<String> = []
        // A host that went away stops contributing its last snapshot at
        // once; one that's merely unreachable keeps its previous one.
        snapshots = snapshots.filter { id, _ in hosts.contains { $0.id == id } }
        for (host, snapshot) in answered {
            guard let snapshot else { continue }
            guard let hostFleets = fleets(in: snapshot) else {
                decodeFailure = "couldn't read the mirrored fleet data"
                continue
            }
            liveIDs.insert(host.id)
            snapshots[host.id] = snapshot
            perHost.append((hostID: host.id, fleets: hostFleets))
            progress.append((hostID: host.id, byPid: snapshot.progressByPid ?? [:]))
            rates[host.id] = snapshot.tokenRate
            // The QR carries neither label nor emoji — the first
            // snapshot names and emoji's a freshly paired host.
            if host.label.isEmpty || host.emoji.isEmpty {
                MirrorHostStore.update(host.id, defaults) {
                    if $0.label.isEmpty { $0.label = snapshot.machineName }
                    if $0.emoji.isEmpty { $0.emoji = MirrorHost.defaultEmoji(for: snapshot) }
                }
            }
        }
        hosts = MirrorHostStore.load(defaults)   // the name fills above
        // A host that just didn't answer keeps its last progress rows on
        // screen — the same rule the cached snapshot follows. Live hosts
        // come first, so a pid both report resolves to the live one.
        for host in hosts where !liveIDs.contains(host.id) {
            var rows: [Int: SessionProgress] = [:]
            for (key, value) in sessionProgress.byKey where key.hostID == host.id {
                rows[key.pid] = value
            }
            if !rows.isEmpty { progress.append((hostID: host.id, byPid: rows)) }
        }
        sessionProgress.apply(progress, rates: rates)
        let firstLoad = reconcile(perHost)
        sessionProgress.primaryHostID = primaryHostID
        snapshot = primaryHostID.flatMap { snapshots[$0] }
        prefs = snapshot?.prefs
        error = decodeFailure
        // The route that just answered is now the primary host's
        // last-good one; the share extension (#64) reads the pairing
        // through the keychain.
        ShareBridge.publish(host: hosts.first { $0.id == primaryHostID } ?? hosts.first, defaults)
        ShareSuggestions.sync(sessions: liveSessions?.sessions ?? [],
                              name: { sessionProgress.byPid[$0]?.name }, theme: rowTheme)
        AppIcons.follow(themeID: rowTheme.id)
        AwsLoginAlerts.shared.sync(awsLogins)
        if let fleet = primary {
            FleetAlarmCenter.shared.sync(accounts: fleet.accounts, activeNumber: fleet.activeNumber,
                                         macPushesAlerts: snapshot?.pushesAlerts ?? false)
        }
        LiveActivities.shared.sync(
            fleet: primary, machine: snapshot?.machineName ?? "",
            tokenRate: sessionProgress.tokenRate,
            capturedAt: snapshot?.capturedAt ?? .distantPast)
        if firstLoad {
            DispatchQueue.main.async { self.replayIntro() }
        }
    }

    /// The file path — one snapshot, one host. `INFINITUS_MIRROR_PATH(S)`
    /// fixtures and the Documents offline copy both come through here,
    /// so the pre-multi-host behaviour is exactly what it was.
    private func refreshFile() async throws {
        guard let snapshot = try await mirror.latest() else {
            self.snapshot = nil
            snapshots = [:]
            prefs = nil
            error = nil
            fleets = []
            fleetSinks = [:]
            transportStatuses = [:]
            return
        }
        guard let hostFleets = fleets(in: snapshot) else {
            error = "couldn't read the mirrored fleet data"
            return
        }
        // The fixture host this snapshot belongs to (labelled from its
        // machineName), else a synthetic one for the Documents copy —
        // either way the merge below stays one path.
        let host = hosts.first { $0.label == snapshot.machineName } ?? hosts.first
            ?? MirrorHost(id: "file", label: snapshot.machineName,
                          emoji: MirrorHost.defaultEmoji(for: snapshot))
        if hosts.isEmpty { hosts = [host] }
        snapshots = [host.id: snapshot]
        transportStatuses = [:]
        sessionProgress.apply([(hostID: host.id, byPid: snapshot.progressByPid ?? [:])],
                              rates: [host.id: snapshot.tokenRate])
        let firstLoad = reconcile([(hostID: host.id, fleets: hostFleets)])
        sessionProgress.primaryHostID = primaryHostID
        self.snapshot = snapshot
        prefs = snapshot.prefs
        error = nil
        ShareSuggestions.sync(sessions: liveSessions?.sessions ?? [],
                              name: { sessionProgress.byPid[$0]?.name }, theme: rowTheme)
        AppIcons.follow(themeID: rowTheme.id)
        AwsLoginAlerts.shared.sync(awsLogins)
        if let fleet = primary {
            FleetAlarmCenter.shared.sync(accounts: fleet.accounts, activeNumber: fleet.activeNumber,
                                         macPushesAlerts: snapshot.pushesAlerts ?? false)
        }
        LiveActivities.shared.sync(
            fleet: primary, machine: snapshot.machineName, tokenRate: snapshot.tokenRate,
            capturedAt: snapshot.capturedAt)
        if firstLoad {
            DispatchQueue.main.async { self.replayIntro() }
        }
    }

    /// One host's snapshot → its fleets, in popup order (`nil` when an
    /// older Mac's `listJSON` doesn't decode).
    private func fleets(in snapshot: MirrorSnapshot) -> [EngineFleet]? {
        if let snapshotFleets = snapshot.fleets {
            // Newer Mac: one EngineFleet per engine, already in popup
            // order — listJSON is cswap's `raw` bytes under this roof,
            // so it's never re-decoded here.
            return snapshotFleets
        }
        // Older Mac: the only fleet is the legacy listJSON one, wrapped
        // as an EngineFleet so `apply` stays one path.
        guard let list = Self.decodeList(snapshot.listJSON) else { return nil }
        return [EngineFleet(engineID: MirrorFleetModel.cswapEngineID, provider: .claude,
                            accounts: list.accounts, activeNumber: list.activeAccountNumber,
                            nextCandidate: list.nextCandidate, nextRecovery: list.nextRecovery,
                            liveSessions: list.liveSessions, raw: snapshot.listJSON)]
    }

    /// Find-or-create one `MirrorFleetModel` per reported fleet — stable
    /// instances keyed by host + engine across refreshes, same as the
    /// Mac's `EngineRegistry.state(for:)`, so each fleet's ticks and
    /// animations survive the next snapshot AND two hosts' `cswap`
    /// fleets never merge. Returns whether the PRIMARY fleet just loaded
    /// its first snapshot — `refresh` uses that to decide whether to
    /// replay the intro, exactly as `AppModel.refreshSnapshot` does off
    /// `primary`.
    private func reconcile(_ perHost: [(hostID: String, fleets: [EngineFleet])]) -> Bool {
        var existing = Dictionary(uniqueKeysWithValues: fleets.map { ($0.id, $0) })
        var changesByID: [String: MirrorFleetModel.Change] = [:]
        var newFleets: [MirrorFleetModel] = []
        for (hostID, hostFleets) in perHost {
            for ef in hostFleets {
                let key = "\(hostID)/\(ef.key)"
                let fleet: MirrorFleetModel
                if let found = existing.removeValue(forKey: key) {
                    fleet = found
                } else {
                    fleet = MirrorFleetModel(hostID: hostID, engineID: ef.engineID,
                                             provider: ef.provider, host: self)
                    // Delayed mutations (death/revive ticks, the switch
                    // flash) land on the fleet with no coincident publish
                    // here — forward them so every observer of `self`
                    // (haptics, the facade) still sees them.
                    fleetSinks[key] = fleet.objectWillChange
                        .sink { [weak self] _ in self?.objectWillChange.send() }
                }
                changesByID[key] = fleet.apply(ef)
                newFleets.append(fleet)
            }
        }
        for goneID in existing.keys { fleetSinks.removeValue(forKey: goneID) }
        fleets = newFleets
        let primaryID = pickPrimary(newFleets)?.id
        return primaryID.flatMap { changesByID[$0] }?.firstLoad ?? false
    }

    /// The primary Claude fleet — cswap's, on a cswap machine — the
    /// facade below reads (`AppModel`'s exact rule).
    var primary: MirrorFleetModel? { pickPrimary(fleets) }

    /// Which fleet the facade reads once hosts merge (04-phone): the
    /// first host that has a `.claude` fleet WITH accounts — the Mac,
    /// whose cswap list is what the Fleet tab mirrors. A Windows host's
    /// fleet carries `accounts: []` and never wins it; the older
    /// first-Claude-fleet rule is the fallback.
    private func pickPrimary(_ list: [MirrorFleetModel]) -> MirrorFleetModel? {
        list.first { $0.provider == .claude && !$0.accounts.isEmpty }
            ?? list.first { $0.provider == .claude }
            ?? list.first
    }

    /// Intro phase timing, AppModel's formulas: bars (and the active-row
    /// flash) hold until the content entrance has fully landed.
    var introContentDuration: Double { 0.7 / max(0.2, introSpeed) }
    var introBarDelay: Double { introContentDuration + 0.25 }

    /// The whole sequence, not just the entrances — the bars replay via
    /// the introTick environment and the flash fires after the fill, on
    /// the PRIMARY fleet only (AppModel.replayIntro's exact rule).
    func replayIntro() {
        introTick += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + introBarDelay + 0.5) {
            self.primary?.bumpSwitchFlash()
        }
    }

    // MARK: - FleetModel (facade over the primary fleet — AppModel's shape)

    var accounts: [Account] { primary?.accounts ?? [] }
    var activeNumber: Int? { primary?.activeNumber }
    var nextCandidate: Int? { primary?.nextCandidate }
    var nextRecovery: NextRecovery? { primary?.nextRecovery }
    /// Live Claude Code sessions on the mirrored Mac — the footer's brain
    /// chip and the sessions card both read it (#9 phase D2).
    var liveSessions: LiveSessions? { primary?.liveSessions }
    /// #7 on the phone: the Mac's projection and plan, verbatim from the
    /// snapshot — the shared AllDeadBanner renders both lines.
    var forecast: UsageForecast? { snapshot?.forecast }
    var battlePlan: WindowPlanner.Plan? { snapshot?.plan }
    /// The "at this pace" line's tap: NativeFleetScreen pushes OutlookScreen.
    @Published var outlookShown = false
    /// A screen asking the shell to switch tabs (the Fleet hero's
    /// sessions line, a Live Activity tap); RootView consumes it.
    @Published var requestedTab: String?
    /// A shake's capture, with the session it's for; the Sessions tab
    /// opens that feed and the feed moves it into its composer.
    @Published var stagedCapture: StagedCapture?
    /// The AWS login a tapped notification asks for; the Sessions tab
    /// opens its sign-in sheet.
    @Published var requestedAwsLogin: String?
    /// A session just started from here (#91); the Sessions tab opens
    /// its chat once the snapshot lists it.
    @Published var requestedPid: Int?
    /// Folders sessions have run in on the Mac, newest first.
    var recentCwds: [String] { snapshot?.recentCwds ?? [] }
    func openForecast() { outlookShown = true }
    var switchFlashTick: Int { primary?.switchFlashTick ?? 0 }
    var deathTicks: [Int: Int] { primary?.deathTicks ?? [:] }
    var dying: Set<Int> { primary?.dying ?? [] }
    var reviveTicks: [Int: Int] { primary?.reviveTicks ?? [:] }
    var displayAccounts: [Account] { primary?.displayAccounts ?? [] }

    /// What every fleet's `displayAccounts` sorts by (#9 phase D1a):
    /// Follow Mac's mirrored `sortByHeadroom`, else always-on. No local
    /// override exists for this pref.
    var sortByHeadroom: Bool { macPrefs?.sortByHeadroom ?? true }

    /// Custom skins ride in the snapshot — the phone has no themes.json.
    var availableThemes: [RowTheme] { RowTheme.builtins + (prefs?.customThemes ?? []) }
    var rowTheme: RowTheme { availableThemes.first { $0.id == themeID } ?? .off }

    /// Follow Mac supplies everything the Mac exported; with it off (or
    /// with a pre-prefs snapshot) the local overrides win.
    private var macPrefs: FleetPrefs? { followMac ? prefs : nil }
    var themeID: String { macPrefs?.themeID ?? localThemeID }
    var compactRows: Bool { macPrefs?.compactRows ?? localCompactRows }
    var burnStyle: String { macPrefs?.burnStyle ?? localBurnStyle }
    var introStyle: String { macPrefs?.introStyle ?? localIntroStyle }
    var introTitle: String { macPrefs?.introTitle ?? localIntroTitle }
    var introSpeed: Double { macPrefs?.introSpeed ?? localIntroSpeed }

    /// ORIENTATION decides the layout here, not the Mac's pref: portrait
    /// is the card UI, landscape the wide list (user's fidelity rule).
    var popupLayout: String { isLandscape ? "wide" : "stacked" }

    /// A row tap stages a switch on the mac, where an alert commits it.
    /// The phone can't drive the engine, so the staged number is dropped
    /// the moment it's set — `nil` is exactly how the mac renders while
    /// no confirmation is up.
    var pendingSwitch: Int? {
        get { nil }
        set { _ = newValue }
    }

    /// The Mac's footer chips (#9 phase D2), straight off the snapshot.
    /// The engine badge is informational here — `toggleEngine()` keeps
    /// the protocol's no-op, the phone drives no engine.
    var engineBadge: EngineBadge? { snapshot?.engine }
    var serviceStatus: ServiceStatusSummary? { snapshot?.serviceStatus }

    /// The card is rendered INLINE on the phone (the mac pops it over
    /// the brain chip), so the chip's flag never goes up — same
    /// write-it-away shape as `pendingSwitch`.
    var sessionsShown: Bool {
        get { false }
        set { _ = newValue }
    }

    /// AppModel.popupScale's mapping, for the mirrored text-size pref.
    var popupScale: CGFloat {
        switch macPrefs?.popupTextSize ?? "default" {
        case "large": return 1.15
        case "xlarge": return 1.3
        case "huge": return 1.5
        default: return 1
        }
    }

    /// No engine to be missing: the phone reads a mirror, and "no
    /// snapshot yet" is the screen's own empty state.
    var engineMissing: Bool { false }
    var snapshotLoaded: Bool { snapshot != nil }
    /// No transparency dial on the phone — fills render at full strength.
    var fillScale: Double { 1 }
    var isPlayground: Bool { false }
}

/// The sessions card's progress feed on the phone (#9 phase D2): the
/// per-pid `SessionProgress` each host read from its transcripts and put
/// in its snapshot. No transcripts to read here, so `refresh` keeps the
/// protocol's no-op.
@MainActor
final class MobileSessionProgress: ObservableObject, SessionProgressSource {
    /// A session's address once two hosts merge into one list — a pid
    /// alone can't tell two machines' sessions apart.
    struct SessionKey: Hashable {
        let hostID: String
        let pid: Int
    }

    /// Every host's rows, keyed (host, pid) — the merged sessions list
    /// (W14) looks rows up by the same key it keys its rows with.
    @Published private(set) var byKey: [SessionKey: SessionProgress] = [:]
    /// The pre-multi-host shape `SessionProgressSource` still speaks.
    /// When two hosts report the same pid, the earlier one in stored
    /// order — the Mac — wins.
    @Published private(set) var byPid: [Int: SessionProgress] = [:]
    /// Each host's fleet-wide output tokens per minute.
    private var rates: [String: TokenRate] = [:]
    /// Which host's rate `tokenRate` reads — MirrorModel's primary (the
    /// Mac), falling back to whichever host reported one.
    var primaryHostID: String?

    /// One apply per refresh, with every host's rows in stored order, so
    /// both maps are rebuilt whole (a host that dropped off leaves
    /// nothing stale behind).
    func apply(_ perHost: [(hostID: String, byPid: [Int: SessionProgress])],
               rates: [String: TokenRate]) {
        var keyed: [SessionKey: SessionProgress] = [:]
        var pids: [Int: SessionProgress] = [:]
        for (hostID, rows) in perHost {
            for (pid, progress) in rows {
                keyed[SessionKey(hostID: hostID, pid: pid)] = progress
                if pids[pid] == nil { pids[pid] = progress }
            }
        }
        if keyed != byKey { byKey = keyed }
        if pids != byPid { byPid = pids }
        if rates != self.rates { self.rates = rates }
    }

    var tokenRate: TokenRate? {
        rates[primaryHostID ?? ""] ?? rates.values.first
    }
}

/// The cash column's source on the phone (#9 phase D1a): the estimated-
/// spend report the mirror carries verbatim as `usageJSON`, decoded the
/// same way UsageModel's own cache read does on the mac. On-demand, not
/// tied to MirrorModel's snapshot polling — same fidelity as the mac's
/// own cash column, which is a `loadIfNeeded()` cache read too.
@MainActor
final class MobileUsage: ObservableObject, UsageSource {
    @Published private(set) var report: UsageReport?

    private let mirror: FleetMirror
    private var capturedAt: Date?

    init(mirror: FleetMirror? = nil) {
        self.mirror = mirror ?? MirrorModel.makeMirror()
    }

    func loadIfNeeded() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let snapshot = try? await mirror.latest(),
              snapshot.capturedAt != capturedAt,
              let data = snapshot.usageJSON else { return }
        capturedAt = snapshot.capturedAt
        report = try? JSONDecoder().decode(UsageReport.self, from: data)
    }
}

/// What a shake produced and where it belongs (ShakeToSend →
/// SessionsScreen → SessionFeedScreen's composer).
struct StagedCapture: Identifiable {
    let id = UUID()
    let pid: Int
    let image: UIImage
}
