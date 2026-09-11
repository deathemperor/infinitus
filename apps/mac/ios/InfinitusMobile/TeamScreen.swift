import SwiftUI
import UIKit
import InfinitusCore

/// The phone's Team tab (spec §9 step 8): the Mac's team through the
/// mirror. Roster / requests / invite come from the snapshot the phone
/// already polls; aggregates, member detail and actions go over
/// `/mirror/team/*`. Locked behind MobileLock when the switch is on.
struct TeamScreen: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject private var lock = MobileLock.shared
    @Environment(\.scenePhase) private var scenePhase
    /// The leaders' team picture, keyed by `Stats.Period.rawValue` —
    /// whatever they have published; a period they never published is
    /// simply absent (TeamReader.aggregates).
    @State private var aggregates: [String: TeamDocs.Aggregates] = [:]
    @State private var period: Stats.Period = .week
    /// The action in flight, by name — every button is disabled while
    /// one runs (the Mac's git queue serializes them anyway).
    @State private var busy: String?
    @State private var error: String?
    /// The last invite link or team code this phone minted; shown until
    /// the next mint, never persisted.
    @State private var code: String?
    @State private var joinCode = ""
    @State private var joinName = UIDevice.current.name
    @State private var days = 7
    @State private var declining: TeamSnapshot.Request?
    /// The Mac's Nearby, on demand: a scan is a 2 s mDNS browse over
    /// there, so it never runs on a timer.
    @State private var nearby: TeamMirror.NearbyReply?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Group {
                if lock.enabled && lock.locked {
                    lockedView
                } else if let snap = model.team {
                    inTeam(snap)
                } else {
                    notInTeam
                }
            }
            .navigationTitle(model.rowTheme.tabLabel("team"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { lock.relock() } }
        // Joining, approving or leaving on either end changes what the
        // aggregates mean — reload them when the role moves.
        .onChange(of: model.team?.role) { _, _ in Task { await loadAggregates() } }
        .task {
            await loadAggregates()
            await loadNearby()
        }
    }

    // MARK: locked

    private var lockedView: some View {
        VStack(spacing: 16) {
            ThemedPlaceholder(theme: model.rowTheme, key: "empty", plainSymbol: "lock.fill",
                              description: "Unlock with \(lock.methodName) to see your team.")
            Button("Unlock") { Task { _ = await lock.unlock() } }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: no team yet

    private var notInTeam: some View {
        Form {
            Section("Join a team") {
                TextField("Team code or invite link", text: $joinCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Your name", text: $joinName)
                Button("Request to join") {
                    Task {
                        let entered = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        let reply = await act("Requesting…") {
                            try await NetworkFleetMirror.shared.teamJoin(code: entered, name: joinName)
                        }
                        if reply?.ok == true {
                            joinCode = ""
                            await model.refresh()
                        }
                    }
                }
                .disabled(joinCode.isEmpty || busy != nil)
            }
            Section {
                Text("Create a team on the Mac (Settings › Team).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            nearbyTeamsSection
            invitationsSection
            statusSection
        }
    }

    // MARK: in a team

    private func inTeam(_ snap: TeamSnapshot) -> some View {
        Form {
            Section {
                LabeledContent("Team", value: snap.name)
                LabeledContent("You", value: "\(snap.role) · \(myName(snap))")
                LabeledContent("Store") { Text(snap.remote).font(.caption.monospaced()) }
                LabeledContent("Last fetch", value: relative(snap.lastFetch))
                LabeledContent("Last publish", value: relative(snap.lastPublish))
                if snap.role == "pending" {
                    Text("Waiting for a leader to approve you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if snap.role == "leader", !snap.requests.isEmpty {
                requestsSection(snap)
            }
            if snap.role == "leader" { nearbySection(snap) }
            Section("Members") {
                ForEach(snap.members) { member in
                    NavigationLink {
                        TeamMemberScreen(model: model, kid: member.kid, name: member.name)
                    } label: {
                        memberRow(member)
                    }
                    // Nothing readable from them yet: the detail screen
                    // would have nothing to show.
                    .disabled(member.kinds.isEmpty)
                }
            }
            if snap.role == "leader" { inviteSection }
            aggregatesSection
            Section {
                Text("Sharing, exclusions and identity are managed on the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            statusSection
        }
        .refreshable {
            await model.refresh()
            await loadAggregates()
            await loadNearby()
        }
        .confirmationDialog("Decline \(declining?.name ?? "this request")?",
                            isPresented: Binding(get: { declining != nil },
                                                 set: { if !$0 { declining = nil } }),
                            titleVisibility: .visible) {
            Button("Decline", role: .destructive) {
                guard let request = declining else { return }
                declining = nil
                Task {
                    _ = await act("Declining…") {
                        try await NetworkFleetMirror.shared.teamDecline(kid: request.kid)
                    }
                    await model.refresh()
                }
            }
            Button("Cancel", role: .cancel) { declining = nil }
        }
    }

    private func requestsSection(_ snap: TeamSnapshot) -> some View {
        Section("Requests") {
            ForEach(snap.requests) { request in
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.name).bold()
                    Text("\(request.platform) · \(request.devices.joined(separator: ", ")) · \(relative(request.at))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(request.kid)
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .swipeActions(edge: .trailing) {
                    Button("Decline", role: .destructive) { declining = request }
                    Button("Approve") {
                        Task {
                            _ = await act("Approving…") {
                                try await NetworkFleetMirror.shared.teamApprove(kid: request.kid)
                            }
                            // The roster the snapshot carries is the
                            // Mac's — re-read it so the request goes.
                            await model.refresh()
                        }
                    }
                    .tint(.green)
                }
            }
        }
    }

    private func memberRow(_ member: TeamSnapshot.Member) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(member.sessionsNow > 0 ? AnyShapeStyle(.green)
                                             : AnyShapeStyle(.secondary.opacity(0.3)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).bold()
                    Text(member.role).font(.caption).foregroundStyle(.secondary)
                    if member.isMe { Text("you").font(.caption2).foregroundStyle(.tertiary) }
                }
                if let since = member.since { Text("joined \(relative(since))").font(.caption).foregroundStyle(.secondary) }
                Text(member.kinds.isEmpty
                     ? "nothing readable yet"
                     : "shares \(member.kinds.joined(separator: ", ")) · last \(relative(member.lastPublished))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("today \(usd(member.todayUSD)) · \(member.todayMessages) msgs · \(member.todayCommits) commits · \(member.sessionsNow) on")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                ForEach(member.blockers, id: \.self) { blocker in
                    Text("⚠︎ \(blocker)").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var inviteSection: some View {
        Section("Invite") {
            Stepper("Valid \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...30)
            Button("Invite link") { mint(invite: true) }.disabled(busy != nil)
            Button("Team code") { mint(invite: false) }.disabled(busy != nil)
            if let code {
                Text(code)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                ShareLink(item: code) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
    }

    // MARK: nearby (spec §6.4) — the Mac's LAN lists, through the mirror

    private var nearbyPeers: [TeamNearby.Peer] { nearby?.peers ?? [] }
    private var nearbyLeaders: [TeamNearby.Peer] { nearbyPeers.filter { $0.role == "leader" } }

    private var nearbyTeamsSection: some View {
        Section("Nearby teams") {
            if scanning {
                Text("Looking…").font(.caption).foregroundStyle(.secondary)
            } else if nearbyLeaders.isEmpty {
                Text("No discoverable Macs on this network.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(nearbyLeaders) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.name).bold()
                    Text("leads a team · \(peer.host)").font(.caption).foregroundStyle(.secondary)
                    Button("Request to join") {
                        Task {
                            _ = await act("Requesting…") {
                                try await NetworkFleetMirror.shared.teamNearbyRequest(kid: peer.kid ?? "", name: joinName)
                            }
                            await loadNearby()
                        }
                    }
                    .disabled(joinName.isEmpty || busy != nil)
                }
            }
            Button("Scan") { Task { await scanNearby() } }.disabled(busy != nil || scanning)
            Text("Discoverable Macs show their name, kid and team on this network — nothing secret.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var invitationsSection: some View {
        if let invites = nearby?.invites, !invites.isEmpty {
            Section("Invitations") {
                ForEach(invites) { invite in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(invite.fromName) invites you to \(invite.teamName)").bold()
                        HStack {
                            Button("Accept") {
                                Task {
                                    let reply = await act("Accepting…") {
                                        try await NetworkFleetMirror.shared.teamNearbyAccept(fromKid: invite.fromKid, name: joinName)
                                    }
                                    if reply?.ok == true { await model.refresh() }
                                    await loadNearby()
                                }
                            }
                            .disabled(joinName.isEmpty || busy != nil)
                            Button("Ignore", role: .destructive) {
                                Task {
                                    _ = await act("Ignoring…") {
                                        try await NetworkFleetMirror.shared.teamNearbyIgnore(fromKid: invite.fromKid)
                                    }
                                    await loadNearby()
                                }
                            }
                            .disabled(busy != nil)
                        }
                    }
                }
            }
        }
    }

    private func nearbySection(_ snap: TeamSnapshot) -> some View {
        Section("Nearby") {
            ForEach(nearby?.pending ?? []) { request in
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.name).bold()
                    Text("asked over the network · \(request.platform) · \(relative(request.at))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("File for approval") {
                        Task {
                            _ = await act("Filing…") { try await NetworkFleetMirror.shared.teamNearbyPull(kid: request.kid) }
                            await model.refresh()
                            await loadNearby()
                        }
                    }
                    .disabled(busy != nil)
                }
            }
            ForEach(nearbyPeers) { peer in
                VStack(alignment: .leading, spacing: 4) {
                    Text(peer.name).bold()
                    Text("\(peer.role) · \(peer.team == snap.id ? "in this team" : "not in this team")")
                        .font(.caption).foregroundStyle(.secondary)
                    if peer.team == nil {
                        Button("Invite") {
                            Task {
                                _ = await act("Inviting \(peer.name)…") {
                                    try await NetworkFleetMirror.shared.teamNearbyInvite(kid: peer.kid ?? "")
                                }
                                await loadNearby()
                            }
                        }
                        .disabled(busy != nil)
                    }
                }
            }
            if scanning { Text("Looking…").font(.caption).foregroundStyle(.secondary) }
            Button("Scan") { Task { await scanNearby() } }.disabled(busy != nil || scanning)
            Text("Invite a discoverable Mac, or file a request that reached this Mac over the network — either way they land in Requests.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadNearby() async {
        nearby = try? await NetworkFleetMirror.shared.teamNearby()
    }

    private func scanNearby() async {
        scanning = true
        defer { scanning = false }
        do { nearby = try await NetworkFleetMirror.shared.teamNearbyScan() }
        catch { self.error = error.localizedDescription }
    }

    /// The leaders' published picture for the chosen period — read from
    /// the store, not computed here: a member sees exactly what the
    /// leaders sealed for the whole team (spec §8.3).
    private var aggregatesSection: some View {
        Section("Team picture") {
            Picker("Period", selection: $period) {
                ForEach(Stats.Period.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let a = aggregates[period.rawValue] {
                LabeledContent("Members", value: "\(a.members)")
                LabeledContent("Cost", value: usd(a.total.usd))
                LabeledContent("Commits", value: "\(a.total.commits)")
                LabeledContent("Messages", value: "\(a.total.humanMessages)")
                LabeledContent("On now", value: a.onNow.isEmpty ? "nobody" : a.onNow.joined(separator: ", "))
                ForEach(a.repos.prefix(8), id: \.project) { repo in
                    LabeledContent(repo.project) {
                        Text("\(usd(repo.usd)) · \(repo.minutes) min · \(repo.members) people")
                            .monospacedDigit().font(.caption)
                    }
                }
            } else {
                Text("The leaders haven't published a team picture for this period yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        if busy != nil || error != nil {
            Section {
                if let busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: work

    private func mint(invite: Bool) {
        Task {
            let reply = await act(invite ? "Minting a link…" : "Minting a code…") {
                try await NetworkFleetMirror.shared.teamCode(days: days, invite: invite)
            }
            code = reply?.code
        }
    }

    /// One shape for every mirror action: the label shows while it runs,
    /// a not-ok reply becomes the visible error (the Mac says why), and a
    /// transport error says so in the same place.
    @discardableResult
    private func act(_ label: String,
                     _ work: () async throws -> TeamMirror.ActionReply) async -> TeamMirror.ActionReply? {
        busy = label
        defer { busy = nil }
        do {
            let reply = try await work()
            error = reply.ok ? nil : (reply.error ?? "That didn't work")
            return reply
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    private func loadAggregates() async {
        guard model.team != nil else { aggregates = [:]; return }
        aggregates = (try? await NetworkFleetMirror.shared.teamAggregates()) ?? [:]
    }

    // MARK: formatting

    private func myName(_ snap: TeamSnapshot) -> String {
        snap.members.first { $0.isMe }?.name ?? "this Mac"
    }

    private func relative(_ t: Int?) -> String {
        guard let t else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .named
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(t)), relativeTo: Date())
    }

    private func usd(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
