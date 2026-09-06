import Foundation
import SwiftUI
import Combine
import InfinitusCore
import InfinitusUI

/// Reads the fleet mirror a Mac already captured (#9 phase 1's
/// `FleetMirror` seam) and republishes it as view-ready state.
///
/// Coordinates one `MirrorFleetModel` per `EngineFleet` in the snapshot
/// (#9 issue 9), stable instances keyed by engineID across refreshes —
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

    @Published private(set) var snapshot: MirrorSnapshot?
    /// Sessions the Mac says need an AWS sign-in (AwsLoginScreen).
    var awsLogins: [AwsLogin.Item] { snapshot?.awsLogins ?? [] }
    func awsLogin(for pid: Int) -> AwsLogin.Item? {
        awsLogins.first { $0.pid == pid }
    }
    /// The Stats tab's four-period bundle, verbatim from the snapshot
    /// (2026-09-04); `nil` for snapshots captured before this field
    /// existed, or before the Mac's first scan finished.
    var stats: Stats.Bundle? { snapshot?.stats }
    /// The Mac's team (Settings › Team), for the phone's Team tab (plan 8).
    var team: TeamSnapshot? { snapshot?.team }
    /// One engine's fleet per element, in the Mac's popup order.
    @Published private(set) var fleets: [MirrorFleetModel] = []
    private var fleetSinks: [String: AnyCancellable] = [:]
    @Published private(set) var error: String?
    /// #168: the snapshot on screen came from the phone's disk cache
    /// because no route reached the Mac. Connectivity, not age — the
    /// 180 s staleness banner stays for "reachable but old".
    @Published var parked = false
    @Published var parkedSince: Date?
    /// Runs on the parked → reachable edge (Task 7's outbox flush).
    var reachableAgain: (() -> Void)?

    /// One OTHER paired Mac (#144 phase 1): read-only on the phone — only
    /// the primary drives chats, approvals, start-session, widgets and
    /// Live Activities. `pairing` is the persisted identity; the rest is
    /// this refresh's live state.
    struct OtherMac: Identifiable {
        let pairing: MacPairing
        var snapshot: MirrorSnapshot?
        var fleets: [MirrorFleetModel] = []
        var status: String = ""
        /// The snapshot came from that Mac's cache because no route
        /// reached it this poll — `snapshot` stays non-nil while a Mac
        /// is down, so presence alone never says "reachable".
        var parked = false
        var id: String { pairing.id }
    }
    @Published private(set) var others: [OtherMac] = []
    /// One cached `NetworkFleetMirror` per other Mac, reused across
    /// refreshes so its last-good endpoint ordering survives — same
    /// reasoning as `.shared` for the primary.
    private var otherMirrors: [String: NetworkFleetMirror] = [:]

    /// Runs with a Mac's id when that Mac answers after not answering
    /// (or on its first answered poll) — the per-Mac outbox flush (#144
    /// phase 2). Per Mac, not per round: a Mac that stays down must not
    /// re-flush every other Mac's queue every poll.
    var otherReachable: ((String) -> Void)?
    private var othersReachable: Set<String> = []

    // MARK: per-Mac reads (#144 phase 2) — `nil` is the primary and
    // returns exactly what the screens read before other Macs opened.

    func other(_ macId: String) -> OtherMac? { others.first { $0.id == macId } }

    /// The mirror a session's screens talk to: the primary's, or the
    /// cached one for its Mac. An unknown id (forgotten while a feed
    /// was open) falls back to the primary rather than a dead actor.
    func mirror(for macId: String?) -> NetworkFleetMirror {
        guard let macId, let pairing = other(macId)?.pairing else { return .shared }
        return otherMirror(for: pairing)
    }

    func progress(macId: String?, pid: Int) -> SessionProgress? {
        guard let macId else { return sessionProgress.byPid[pid] }
        return other(macId)?.snapshot?.progressByPid?[pid]
    }

    func accountSummary(macId: String?, pid: Int) -> SessionAccountSummary? {
        guard let macId else { return accountSummary(forSessionPid: pid) }
        guard let snapshot = other(macId)?.snapshot,
              let fleets = Self.engineFleets(from: snapshot) else { return nil }
        return SessionAccountLookup.summarize(pid: pid, fleets: fleets)
    }

    func fleets(macId: String?) -> [MirrorFleetModel] {
        guard let macId else { return fleets }
        return other(macId)?.fleets ?? []
    }

    func awsLogin(macId: String?, pid: Int) -> AwsLogin.Item? {
        guard let macId else { return awsLogin(for: pid) }
        return other(macId)?.snapshot?.awsLogins?.first { $0.pid == pid }
    }

    func birth(macId: String?, pid: Int) -> SessionBirth? {
        guard let macId else { return snapshot?.births?[pid] }
        return other(macId)?.snapshot?.births?[pid]
    }

    func transportStatus(macId: String?) -> String {
        guard let macId else { return transportStatus }
        return other(macId)?.status ?? ""
    }

    func macName(_ macId: String?) -> String? {
        macId.flatMap { other($0)?.pairing.name }
    }

    /// The Mac a session starts on (#144 phase 3): its profiles, its
    /// folders, its name. `nil` is the primary.
    func profiles(macId: String?) -> [SessionProfile] {
        guard let macId else { return snapshot?.profiles ?? [] }
        return other(macId)?.snapshot?.profiles ?? []
    }

    func recentCwds(macId: String?) -> [String] {
        guard let macId else { return recentCwds }
        return other(macId)?.snapshot?.recentCwds ?? []
    }

    func machineName(macId: String?) -> String {
        guard let macId else { return snapshot?.machineName ?? "the Mac" }
        return other(macId)?.pairing.name ?? "the Mac"
    }

    /// Pull-to-refresh and post-action refresh for a session's own Mac.
    func refresh(macId: String?) async {
        if macId == nil { await refresh() } else { await refreshOthers() }
    }

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
    /// is pointed at a file with INFINITUS_MIRROR_PATH).
    private let usesLAN: Bool

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

    // MARK: LAN transport (#9)

    /// Every `host:port` (or pairing-QR URL) the phone will try, in order
    /// — empty means "use Bonjour only". The mirror reads the same list
    /// straight from UserDefaults (#9 pair once, every route).
    @Published var manualEndpoints: [String] {
        didSet {
            defaults.set(manualEndpoints, forKey: NetworkFleetMirror.manualKey)
            ShareBridge.publish(defaults)
        }
    }
    /// The Mac's pairing token (#9 remote access): without it every
    /// request comes back 401, whether the Mac was found by Bonjour, by
    /// address, or through a tunnel.
    @Published var pairToken: String {
        didSet {
            // What's stored is always the normalised token, so a token
            // typed with lowercase or dashes still matches; assigning
            // back to `pairToken` re-enters `didSet` (Swift does fire it
            // for a nested assignment) and only tidies the field.
            let normalized = MirrorPairing.normalize(pairToken)
            defaults.set(normalized, forKey: NetworkFleetMirror.tokenKey)
            if normalized != pairToken { pairToken = normalized }
            ShareBridge.publish(defaults)
        }
    }
    /// What the Settings screen shows about the connection.
    @Published private(set) var transportStatus = ""

    init(mirror: FleetMirror? = nil, defaults: UserDefaults = .standard) {
        self.mirror = mirror ?? Self.makeMirror()
        self.defaults = defaults
        usesLAN = mirror == nil && ProcessInfo.processInfo
            .environment["INFINITUS_MIRROR_PATH"] == nil
        manualEndpoints = NetworkFleetMirror.storedEndpoints(defaults)
        pairToken = defaults.string(forKey: NetworkFleetMirror.tokenKey) ?? ""
        followMac = defaults.object(forKey: "follow_mac") as? Bool ?? true
        localThemeID = defaults.string(forKey: "gamification_style") ?? "off"
        localCompactRows = defaults.object(forKey: "compact_rows") as? Bool ?? false
        localBurnStyle = defaults.string(forKey: "burn_style") ?? "ember"
        localIntroStyle = defaults.string(forKey: "intro_style") ?? "top"
        localIntroTitle = defaults.string(forKey: "intro_title") ?? "zoom"
        localIntroSpeed = defaults.object(forKey: "intro_speed") as? Double ?? 1.0
        macPopupView = defaults.object(forKey: "mac_popup_view") as? Bool ?? false
        reachableAgain = { Task { await OutboxDelivery.flush() } }
        otherReachable = { id in Task { await OutboxDelivery.flush(macId: id) } }
    }

    /// Pairs with a Mac from a scanned QR or an `infinitus://pair?…` deep
    /// link. Today's behaviour — every route the QR carries replaces the
    /// stored list (#9 pair once, every route), the token beside it — is
    /// kept for the first Mac, or a rescan of the current primary; a scan
    /// of any OTHER Mac ADDS it instead (#144 phase 1). Returns false for
    /// anything that isn't one of our pair URLs.
    @discardableResult
    func applyPairing(_ text: String) -> Bool {
        guard let pairing = MirrorPairing.parsePairURL(text) else { return false }
        if MirrorPairing.Others.replacesPrimary(scannedToken: pairing.token,
                                                primaryToken: pairToken, primaryEndpoints: manualEndpoints,
                                                scannedEndpoints: pairing.endpoints) {
            manualEndpoints = pairing.endpoints
            pairToken = pairing.token
            Task { await refresh() }
            return true
        }
        let id = MirrorPairing.normalize(pairing.token)
        let host = MirrorTransport.parseEndpoint(pairing.endpoint)?.host ?? pairing.endpoint
        let mac = MacPairing(id: id, name: host, endpoints: pairing.endpoints, token: pairing.token)
        MacPairing.save(MirrorPairing.Others.upsert(mac, into: MacPairing.load(defaults)), defaults)
        otherMirrors.removeValue(forKey: id)
        Task { await refresh() }
        return true
    }

    /// Settings › Devices, "Other Macs": drops a pairing for good.
    func forgetOther(id: String) {
        // Its parked cache and queued messages go with it — nothing would
        // flush them once the pairing is gone (#144 phase 3).
        if let token = other(id)?.pairing.token {
            let key = NetworkFleetMirror.parkedKey(token: token)
            NetworkFleetMirror.parkedCache(key: key).clear()
            for item in OutboxDelivery.outbox.items(macKey: key) { OutboxDelivery.outbox.remove(id: item.id) }
        }
        var list = MacPairing.load(defaults)
        list.removeAll { $0.id == id }
        MacPairing.save(list, defaults)
        otherMirrors.removeValue(forKey: id)
        others.removeAll { $0.id == id }
    }

    /// Settings › Devices, "Make primary": the chosen other Mac's
    /// endpoints and token become the primary's; the demoted former
    /// primary re-enters `others` under its last-known name.
    func makePrimary(id: String) {
        let list = MacPairing.load(defaults)
        guard let chosen = list.first(where: { $0.id == id }) else { return }
        let swapped = MirrorPairing.Others.swapPrimary(
            oldPrimary: MirrorPairing.Pairing(endpoints: manualEndpoints, token: pairToken),
            oldPrimaryName: snapshot?.machineName ?? "the Mac", chosen: chosen, others: list)
        // The chosen Mac's own last-good route, not the demoted primary's
        // — otherwise ShareBridge ships a mismatched (new endpoints, old
        // last-good) pair to the share extension.
        if let lastGood = chosen.lastGood {
            defaults.set(lastGood, forKey: NetworkFleetMirror.lastGoodKey)
        } else {
            defaults.removeObject(forKey: NetworkFleetMirror.lastGoodKey)
        }
        manualEndpoints = swapped.primary.endpoints
        pairToken = swapped.primary.token
        MacPairing.save(swapped.others, defaults)
        otherMirrors.removeValue(forKey: id)
        others.removeAll { $0.id == id }
        snapshot = nil
        Task {
            // The old primary's cached snapshot must not linger under the
            // new pairing if the new one fails to answer right away.
            await NetworkFleetMirror.shared.forgetCached()
            await refresh()
        }
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

    /// `INFINITUS_MIRROR_PATH` lets a simulator point at the Mac's live
    /// export; otherwise the LAN transport (#9) fetches the snapshot from
    /// whichever Mac advertises `_infinitus._tcp`, with the app's own
    /// Documents copy as the offline fallback.
    /// `fileprivate`, not `private`: `MobileUsage` below reuses it to read
    /// the same snapshot independently (#9 phase D1a).
    fileprivate static func makeMirror() -> FleetMirror {
        if let path = ProcessInfo.processInfo.environment["INFINITUS_MIRROR_PATH"] {
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
            guard let snapshot = try await mirror.latest() else {
                self.snapshot = nil
                prefs = nil
                error = nil
                fleets = []
                fleetSinks = [:]
                parked = false
                parkedSince = nil
                if usesLAN { transportStatus = await NetworkFleetMirror.shared.statusText }
                refreshOthersDetached()
                return
            }
            guard let engineFleets = Self.engineFleets(from: snapshot) else {
                error = "couldn't read the mirrored fleet data"
                refreshOthersDetached()
                return
            }
            self.snapshot = snapshot
            let fromCache = usesLAN ? await NetworkFleetMirror.shared.lastServedFromCache : false
            let wasParked = parked
            parked = fromCache
            parkedSince = fromCache ? snapshot.capturedAt : nil
            if wasParked, !fromCache { reachableAgain?() }
            prefs = snapshot.prefs
            if usesLAN { transportStatus = await NetworkFleetMirror.shared.statusText }
            // The route that just answered is now the last-good one; the
            // share extension (#64) reads the pairing through the keychain.
            ShareBridge.publish(defaults)
            ShareSuggestions.sync(sessions: liveSessions?.sessions ?? [],
                                  name: { sessionProgress.byPid[$0]?.name }, theme: rowTheme)
            AppIcons.follow(themeID: rowTheme.id)
            sessionProgress.apply(snapshot.progressByPid ?? [:], tokenRate: snapshot.tokenRate)
            let firstLoad = reconcile(engineFleets)
            // The app launched with the Mac reachable and may still hold
            // outbox items from a previous, unparked session.
            if firstLoad, !fromCache { reachableAgain?() }
            error = nil
            AwsLoginAlerts.shared.sync(snapshot.awsLogins ?? [])
            if let fleet = fleets.first(where: { $0.provider == .claude }) ?? fleets.first {
                FleetAlarmCenter.shared.sync(accounts: fleet.accounts, activeNumber: fleet.activeNumber,
                                             macPushesAlerts: snapshot.pushesAlerts ?? false,
                                             lead: reviveLead)
            }
            LiveActivities.shared.sync(
                fleet: fleets.first { $0.provider == .claude } ?? fleets.first,
                machine: snapshot.machineName, tokenRate: snapshot.tokenRate,
                capturedAt: snapshot.capturedAt)
            if firstLoad {
                DispatchQueue.main.async { self.replayIntro() }
            }
            refreshOthersDetached()
        } catch {
            self.error = error.localizedDescription
            refreshOthersDetached()
        }
    }

    /// Pure decode of one snapshot into the `EngineFleet`s `reconcile`
    /// applies — shared with `refreshOthers` so an other Mac's fleets
    /// come from the exact same rule (`nil` on an unreadable legacy
    /// snapshot).
    private static func engineFleets(from snapshot: MirrorSnapshot) -> [EngineFleet]? {
        if let snapshotFleets = snapshot.fleets {
            // Newer Mac: one EngineFleet per engine, already in popup
            // order — listJSON is cswap's `raw` bytes under this roof,
            // so it's never re-decoded here.
            return snapshotFleets
        }
        // Older Mac: the only fleet is the legacy listJSON one, wrapped
        // as an EngineFleet so `apply` stays one path.
        guard let list = decodeList(snapshot.listJSON) else { return nil }
        return [EngineFleet(
            engineID: MirrorFleetModel.cswapEngineID, provider: .claude,
            accounts: list.accounts, activeNumber: list.activeAccountNumber,
            nextCandidate: list.nextCandidate, nextRecovery: list.nextRecovery,
            liveSessions: list.liveSessions, raw: snapshot.listJSON)]
    }

    /// Refreshes every OTHER paired Mac concurrently (#144 phase 1),
    /// each through its own cached `NetworkFleetMirror(pairing:)` so one
    /// dead Mac's retries don't hold up the rest. Read-only: no Live
    /// Activities, widgets or share bridge for these.
    /// Other Macs never delay the primary: their round runs as its own
    /// task after the primary has published, one in flight at a time
    /// (an asleep Mac costs its whole candidate list in timeouts).
    private var refreshingOthers = false
    private func refreshOthersDetached() {
        guard !refreshingOthers else { return }
        refreshingOthers = true
        Task { [weak self] in
            await self?.refreshOthers()
            self?.refreshingOthers = false
        }
    }

    private func refreshOthers() async {
        let pairings = MacPairing.load(defaults)
        let ids = Set(pairings.map(\.id))
        otherMirrors = otherMirrors.filter { ids.contains($0.key) }
        guard !pairings.isEmpty else { others = []; return }
        let mirrors = pairings.map { ($0, otherMirror(for: $0)) }
        // `for await` yields in COMPLETION order, not the pairings' own
        // order — collecting by id and remapping keeps the Fleet/
        // Sessions/Settings sections from reordering every poll.
        let fetched = await withTaskGroup(of: (String, MirrorSnapshot?, String, Bool).self) { group in
            for (pairing, mirror) in mirrors {
                group.addTask {
                    let snapshot = try? await mirror.latest()
                    return (pairing.id, snapshot, await mirror.statusText, await mirror.lastServedFromCache)
                }
            }
            var collected: [String: (MirrorSnapshot?, String, Bool)] = [:]
            for await (id, snapshot, status, parked) in group { collected[id] = (snapshot, status, parked) }
            return collected
        }
        let existingByID = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
        others = pairings.map { pairing in
            guard let (snapshot, status, parked) = fetched[pairing.id] else {
                return OtherMac(pairing: pairing, status: "")
            }
            // Show the Mac's own name the moment it answers, not a poll
            // later — `renameOther` is what makes it stick.
            var named = pairing
            if let snapshot, snapshot.machineName != pairing.name {
                named.name = snapshot.machineName
                renameOther(id: pairing.id, to: snapshot.machineName)
            }
            var other = OtherMac(pairing: named, snapshot: snapshot, status: status, parked: parked)
            guard let snapshot, let engineFleets = Self.engineFleets(from: snapshot) else { return other }
            other.fleets = reconcileFleets(engineFleets, existing: existingByID[pairing.id]?.fleets ?? [],
                                           hostUsage: false).fleets
            return other
        }
        // Per-Mac reachable edge: newly answering ids fire once; a Mac
        // still down stays out of the set and fires nothing. Keyed on
        // `parked`, not snapshot presence: `latest()` hands back the
        // cached snapshot while a Mac is down, so a Mac that slept and
        // woke within one app run would otherwise never fire again.
        let answered = Set(others.compactMap { $0.snapshot != nil && !$0.parked ? $0.id : nil })
        let newlyReachable = answered.subtracting(othersReachable)
        othersReachable = answered
        for id in newlyReachable { otherReachable?(id) }
    }

    /// The cached actor for one other Mac — created once per pairing so
    /// its last-good endpoint ordering survives across refreshes, and
    /// its successful route is written back into `mirror_other_macs`.
    private func otherMirror(for pairing: MacPairing) -> NetworkFleetMirror {
        if let existing = otherMirrors[pairing.id] { return existing }
        let id = pairing.id
        let mirror = NetworkFleetMirror(pairing: pairing) { [weak self] endpoint in
            Task { @MainActor in self?.recordOtherLastGood(id: id, endpoint: endpoint) }
        }
        otherMirrors[id] = mirror
        return mirror
    }

    private func recordOtherLastGood(id: String, endpoint: String) {
        var list = MacPairing.load(defaults)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].lastGood = endpoint
        MacPairing.save(list, defaults)
    }

    private func renameOther(id: String, to name: String) {
        var list = MacPairing.load(defaults)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].name = name
        MacPairing.save(list, defaults)
    }

    /// Find-or-create one `MirrorFleetModel` per reported fleet — stable
    /// instances keyed by engineID across refreshes, same as the Mac's
    /// `EngineRegistry.state(for:)`, so each fleet's ticks/animations
    /// survive the next snapshot. Returns whether the PRIMARY fleet
    /// (first Claude fleet, else the first) just loaded its first
    /// snapshot — `refresh` uses that to decide whether to replay the
    /// intro, exactly as `AppModel.refreshSnapshot` does off `primary`.
    private func reconcile(_ engineFleets: [EngineFleet]) -> Bool {
        let previousIDs = Set(fleets.map(\.id))
        let (newFleets, changesByID) = reconcileFleets(engineFleets, existing: fleets)
        for fleet in newFleets where !previousIDs.contains(fleet.id) {
            // Delayed mutations (death/revive ticks, the switch flash)
            // land on the fleet with no coincident publish here —
            // forward them so every observer of `self` (haptics, the
            // facade) still sees them.
            fleetSinks[fleet.id] = fleet.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
        }
        let newIDs = Set(newFleets.map(\.id))
        for goneID in previousIDs.subtracting(newIDs) { fleetSinks.removeValue(forKey: goneID) }
        fleets = newFleets
        let primaryID = (newFleets.first { $0.provider == .claude } ?? newFleets.first)?.id
        return primaryID.flatMap { changesByID[$0] }?.firstLoad ?? false
    }

    /// The pure find-or-create diff, shared by the primary's `reconcile`
    /// (which also tracks sinks/first-load above) and `refreshOthers`
    /// (neither of which an other Mac needs).
    private func reconcileFleets(_ engineFleets: [EngineFleet], existing existingFleets: [MirrorFleetModel],
                                 hostUsage: Bool = true)
        -> (fleets: [MirrorFleetModel], changesByID: [String: MirrorFleetModel.Change]) {
        var existing = Dictionary(uniqueKeysWithValues: existingFleets.map { ($0.id, $0) })
        var changesByID: [String: MirrorFleetModel.Change] = [:]
        var newFleets: [MirrorFleetModel] = []
        for ef in engineFleets {
            let fleet = existing.removeValue(forKey: ef.key)
                ?? MirrorFleetModel(engineID: ef.engineID, provider: ef.provider, host: self, hostUsage: hostUsage)
            changesByID[ef.key] = fleet.apply(ef)
            newFleets.append(fleet)
        }
        return (newFleets, changesByID)
    }

    /// The primary Claude fleet — cswap's, on a cswap machine — the
    /// facade below reads (`AppModel`'s exact rule).
    var primary: MirrorFleetModel? {
        fleets.first { $0.provider == .claude } ?? fleets.first
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
    /// The Mac `requestedPid` lives on (#144 phase 3); `nil` is the
    /// primary. Set BEFORE `requestedPid` so its observer sees both.
    @Published var requestedMacId: String?
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
    /// Seconds before a reset that a row's countdown goes live and the
    /// reset alarm fires — the Mac's knob, or its default when not mirrored.
    var reviveLead: TimeInterval { TimeInterval((macPrefs?.reviveLeadMinutes ?? 10) * 60) }

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
/// per-pid `SessionProgress` the Mac already read from its transcripts
/// and put in the snapshot. No transcripts to read here, so `refresh`
/// keeps the protocol's no-op.
@MainActor
final class MobileSessionProgress: ObservableObject, SessionProgressSource {
    @Published private(set) var byPid: [Int: SessionProgress] = [:]
    @Published private(set) var tokenRate: TokenRate?

    func apply(_ byPid: [Int: SessionProgress], tokenRate: TokenRate?) {
        if byPid != self.byPid { self.byPid = byPid }
        if tokenRate != self.tokenRate { self.tokenRate = tokenRate }
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
