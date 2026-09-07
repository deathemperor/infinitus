import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import InfinitusCore

/// Settings › Team (spec §9). Not in a team: Create / Join, both behind
/// the biometric-lock gate (§2.2). In a team: header + loop state,
/// requests (leaders), members, invite / team code (leaders), sharing,
/// exclusions, privacy (Leave). Grouped Form like LockPane; every action
/// goes through TeamModel and re-renders from its snapshot.
struct TeamPane: View {
    @ObservedObject var team: TeamModel
    @ObservedObject var lock: LockModel
    @ObservedObject var feed: TeamControlFeed

    var body: some View {
        // NavigationStack so a member row's "Detail" link pushes TeamMemberPane.
        NavigationStack {
            Form {
                if let snap = team.snapshot {
                    inTeam(snap)
                } else {
                    notInTeam
                }
                if let err = team.lastError {
                    Section { Text(err).font(.caption).foregroundStyle(.orange) }
                }
            }
            .formStyle(.grouped)
            .disabled(team.busy != nil)
            .overlay(alignment: .top) {
                if let line = statusLine {
                    HStack { ProgressView().controlSize(.small); Text(line) }
                        .font(.caption).padding(6).background(.thinMaterial, in: Capsule()).padding(.top, 6)
                }
            }
            .onAppear { team.load() }
            // On the Form, not on inTeam's Group: a Group hands its modifier
            // to every child, which would arm one alert per Section.
            .alert("Remove \(removeTarget?.name ?? "")?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
                Button("Remove", role: .destructive) { if let t = removeTarget { Task { await team.remove(kid: t.kid) } }; removeTarget = nil }
                Button("Cancel", role: .cancel) { removeTarget = nil }
            } message: {
                Text("They stop reading anything published after now and see \"Removed\" on their next fetch. What they already fetched stays theirs.")
            }
            .sheet(isPresented: $showRecovery) { TeamRecoveryKeySheet(team: team) }
            .sheet(isPresented: $showExport) { TeamExportSheet(team: team) }
            .sheet(isPresented: $showImport) { TeamImportSheet(team: team) }
            .sheet(isPresented: $showGrant) { if let snap = team.snapshot { TeamGrantSheet(team: team, snap: snap) } }
        }
    }

    // MARK: not in a team

    @State private var createName = ""
    @State private var leaderName = NSFullUserName()
    @State private var remote = ""
    @State private var token = ""
    @State private var joinCode = ""
    @State private var joinName = NSFullUserName()
    @State private var showRecovery = false
    @State private var showExport = false
    @State private var showImport = false
    @State private var showGrant = false
    @State private var cfZone = ""
    @State private var cfLabel = TeamHostnames.defaultLabel
    @State private var cfToken = ""

    private var gateOpen: Bool { if case .allowed = team.gate() { return true } else { return false } }

    private var notInTeam: some View {
        Group {
            if !gateOpen {
                Section {
                    HStack {
                        Label(TeamGate.reason, systemImage: "lock")
                        Spacer()
                        Button("Open Lock settings") { lock.revealSetting() }
                    }
                    Text("Create team and Request to join stay disabled until biometric unlock is on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Create a team") {
                TextField("Team name", text: $createName)
                TextField("Your name", text: $leaderName)
                TextField("Empty private repo URL", text: $remote)
                SecureField("Write token (optional; stays in the keychain)", text: $token)
                Text("Paste the URL of an empty private repo and a token that can push to it — or an ssh URL your agent can use. The only out-of-app step.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Create team") {
                    Task { await team.create(name: createName, remote: remote, token: token, leaderName: leaderName); token = "" }
                }
                .disabled(!gateOpen || createName.isEmpty || remote.isEmpty || leaderName.isEmpty)
            }
            Section("Join a team") {
                TextField("Your name", text: $joinName)
                TextField("Team code or invite link", text: $joinCode, axis: .vertical).lineLimit(2...4)
                    .onAppear { if let pending = team.pendingCode { joinCode = pending } }
                    .onChange(of: team.pendingCode) { _, pending in if let pending { joinCode = pending } }
                Button("Request to join") { Task { await team.join(code: joinCode, name: joinName) } }
                    .disabled(!gateOpen || joinCode.isEmpty || joinName.isEmpty)
                if let kid = team.kid {
                    LabeledContent("Your identity") { Text(kid).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            Section("Nearby teams") {
                if team.nearby.isEmpty {
                    Text(team.scanning ? "Looking…" : "No discoverable Macs on this network.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(team.nearby.filter { $0.role == "leader" }) { peer in
                    HStack {
                        VStack(alignment: .leading) { Text(peer.name).bold(); Text("leads a team · \(peer.host)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Request to join") { Task { await team.requestNearby(peer, name: joinName) } }.disabled(!gateOpen || joinName.isEmpty)
                    }
                }
                HStack {
                    Button(team.scanning ? "Scanning…" : "Scan") { Task { await team.scanNearby() } }.disabled(team.scanning)
                    Toggle("Discoverable", isOn: $team.discoverable).toggleStyle(.switch)
                }
                Text("Discoverable Macs show their name, kid and team on this network (nothing secret). Leaders see your request in Requests.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task { await team.scanNearby() }
            if !team.invites.isEmpty {
                Section("Invitations") {
                    ForEach(team.invites) { invite in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(invite.fromName) invites you to \(invite.teamName)").bold()
                                Text(invite.from.kid).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Accept") { Task { await team.acceptInvite(invite, name: joinName) } }
                                .disabled(!gateOpen || joinName.isEmpty)
                            Button("Ignore") { Task { await team.ignoreInvite(invite) } }
                        }
                    }
                    Text("The invitation stays sealed on this Mac until you accept; accepting joins straight away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Identity") {
                identityButtons
                Text("A recovery key or an export file moves this Mac's identity to another Mac — import one before joining, not after.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Spec §2.1: recovery and export need an identity to exist; import
    /// replaces whatever is there.
    @ViewBuilder private var identityButtons: some View {
        if team.kid != nil {
            Button("Show recovery key…") { showRecovery = true }
            Button("Export identity…") { team.clearError(); showExport = true }
        }
        Button("Import identity…") { team.clearError(); showImport = true }
    }

    // MARK: in a team

    @State private var codeDays = 7
    @State private var removeTarget: TeamSnapshot.Member?
    @State private var leaveConfirm = false
    @State private var reshareConfirm = false

    private func inTeam(_ snap: TeamSnapshot) -> some View {
        Group {
            Section {
                LabeledContent("Team", value: snap.name)
                LabeledContent("You", value: "\(snap.role)\(snap.members.first(where: \.isMe).map { " · \($0.name)" } ?? "")")
                LabeledContent("Store") { Text(snap.remote).font(.caption.monospaced()).textSelection(.enabled) }
                LabeledContent("Last fetch", value: relative(snap.lastFetch))
                LabeledContent("Last publish", value: relative(snap.lastPublish))
                HStack {
                    Button("Fetch now") { Task { await team.fetchNow() } }
                    Button("Publish now") { Task { await team.publishNow() } }
                    if snap.role == "pending" { Text("Waiting for a leader to approve you.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if snap.role == "leader", !snap.requests.isEmpty {
                Section("Requests") {
                    ForEach(snap.requests) { r in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(r.name).bold()
                                Text("\(r.platform) · \(r.devices.joined(separator: ", ")) · \(relative(r.at))").font(.caption).foregroundStyle(.secondary)
                                Text(r.kid).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Approve") { Task { await team.approve(kid: r.kid) } }.disabled(!gateOpen)
                            Button("Decline") { Task { await team.decline(kid: r.kid) } }
                        }
                    }
                }
            }
            if snap.role == "leader" {
                Section("Nearby") {
                    ForEach(team.pendingNearby, id: \.doc.keys.kid) { r in
                        HStack {
                            VStack(alignment: .leading) { Text(r.doc.name).bold(); Text("asked over the network · \(r.doc.platform) · \(relative(r.doc.at))").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("File for approval") { Task { await team.pullNearbyRequest(r) } }
                        }
                    }
                    ForEach(team.nearby) { peer in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peer.name).bold()
                                Text("\(peer.role) · \(peer.team == snap.id ? "in this team" : "not in this team")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if peer.team == nil {
                                Button("Invite") { Task { await team.inviteNearby(peer) } }.disabled(!gateOpen)
                            }
                        }
                    }
                    HStack {
                        Button(team.scanning ? "Scanning…" : "Scan") { Task { await team.scanNearby() } }.disabled(team.scanning)
                        Toggle("Discoverable", isOn: $team.discoverable).toggleStyle(.switch)
                    }
                    Text("Members can request to join from their Team pane, or you can invite a discoverable Mac; either way they appear in Requests once approved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .task { await team.scanNearby() }
            }
            Section("Members") {
                ForEach(snap.members) { m in memberRow(m, leader: snap.role == "leader") }
                if snap.members.isEmpty { Text("No roster yet.").foregroundStyle(.secondary) }
            }
            if snap.role == "leader" { TeamInsightsSection(team: team) } else { TeamMembersViewSection(team: team) }
            if snap.role == "leader" { inviteSection }
            if snap.role == "leader", let policy = team.policy { policySection(policy) }
            sharingSection(snap)
            controlSection(snap)
            if snap.role == "leader" { hostnamesSection(snap) }
            exclusionsSection
            Section("Privacy") {
                Text("You publish \(sharedKinds()) to the audiences above; everything is encrypted to them before it leaves this Mac. The store host sees file names and sizes only.")
                    .font(.caption).foregroundStyle(.secondary)
                if let kid = team.kid {
                    LabeledContent("Your identity") { Text(kid).font(.caption.monospaced()).textSelection(.enabled) }
                }
                identityButtons
                Button("Leave team…", role: .destructive) { leaveConfirm = true }
                    .confirmationDialog("Leave \(snap.name)?", isPresented: $leaveConfirm) {
                        Button("Leave", role: .destructive) { Task { await team.leave() } }
                        Button("Stay", role: .cancel) {}
                    } message: {
                        Text("Your files are deleted from the store and the leaders are told. Your local history stays; your identity stays.")
                    }
            }
        }
    }

    private func memberRow(_ m: TeamSnapshot.Member, leader: Bool) -> some View {
        HStack(alignment: .top) {
            Circle().fill(m.sessionsNow > 0 ? Color.green : Color.secondary.opacity(0.3)).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.name).bold()
                    Text(m.role).font(.caption).foregroundStyle(.secondary)
                    if m.founder { Text("founder").font(.caption2).foregroundStyle(.tertiary) }
                    if m.isMe { Text("you").font(.caption2).foregroundStyle(.tertiary) }
                }
                if let since = m.since { Text("joined \(relative(since))").font(.caption).foregroundStyle(.secondary) }
                Text(m.kinds.isEmpty ? "nothing readable yet" : "shares \(m.kinds.joined(separator: ", ")) · last \(relative(m.lastPublished))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("today \(m.todayUSD, format: .currency(code: "USD").precision(.fractionLength(2))) · \(m.todayMessages) messages · \(m.todayCommits) commits · \(m.sessionsNow) on now")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                ForEach(m.blockers, id: \.self) { Text("⚠︎ \($0)").font(.caption).foregroundStyle(.orange) }
                if m.crashes > 0 { Text("\(m.crashes) crash report\(m.crashes == 1 ? "" : "s")").font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if !m.kinds.isEmpty {
                NavigationLink("Detail") { TeamMemberPane(team: team, kid: m.kid) }
                    .buttonStyle(.link)
            }
            if leader, !m.isMe {
                Menu {
                    if m.role == "member" { Button("Promote to leader") { Task { await team.promote(kid: m.kid) } } }
                    Button("Remove…", role: .destructive) { removeTarget = m }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 24)
            }
        }
    }

    private var inviteSection: some View {
        Section("Invite") {
            HStack {
                Picker("Valid for", selection: $codeDays) {
                    Text("1 day").tag(1); Text("7 days").tag(7); Text("30 days").tag(30); Text("1 year").tag(365)
                }
                .frame(maxWidth: 200)
                Button("Invite link (approved automatically)") { Task { await team.mintInvite(days: codeDays) } }
                Button("Team code (needs Approve)") { Task { await team.mintCode(days: codeDays) } }
            }
            Text("An invite link approves the one request it was minted for by itself when the switch below is on; a team code always needs your Approve. Both carry the store credential, so anyone holding one can write to the store until you rotate it — share as widely as you'd share the repo.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Approve invited requests automatically", isOn: Binding(get: { team.autoApprove }, set: { team.setAutoApprove($0) }))
            Text("Off by default: a request echoes its invite's nonce in the clear, so while this is on, anyone holding the store credential can copy a pending invitee's nonce and be approved without your tap.")
                .font(.caption).foregroundStyle(.secondary)
            if let code = team.code {
                VStack(alignment: .leading, spacing: 8) {
                    if let image = Self.qr(code) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160)
                    }
                    Text(code).font(.caption2.monospaced()).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    HStack {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                        Button("Share…") { share(code) }
                        Button("Done") { team.clearCode() }
                    }
                }
            }
        }
    }

    private func policySection(_ policy: TeamRoster.Policy) -> some View {
        Section("Policy") {
            Picker("Requests", selection: Binding(get: { policy.requests }, set: { new in Task { await team.setPolicy(requests: new, membersSeeEachOther: policy.membersSeeEachOther) } })) {
                Text("By code or invite").tag("code")
                Text("Closed").tag("off")
            }
            Toggle("Members see each other's detail", isOn: Binding(get: { policy.membersSeeEachOther }, set: { new in Task { await team.setPolicy(requests: policy.requests, membersSeeEachOther: new) } }))
            Text("Closed: no new codes, and the network endpoint refuses requests. Members see each other: leaders re-publish member detail to the team.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sharingSection(_ snap: TeamSnapshot) -> some View {
        Section("What you share, and with whom") {
            ForEach(TeamKinds.memberKinds, id: \.self) { kind in
                Picker(kindTitle(kind), selection: Binding(
                    get: { audienceTag(team.shares.target(for: kind)) },
                    set: { tag in Task { await team.setShare(kind: kind, target: audience(from: tag, snap)) } })) {
                    Text("Nobody").tag("off")
                    Text("Leaders").tag("leaders")
                    Text("Whole team").tag("team")
                    ForEach(snap.members.filter { !$0.isMe }) { m in Text("Only \(m.name)").tag("kid:\(m.kid)") }
                }
            }
            if team.shares.target(for: TeamKinds.transcripts) != .off {
                Picker("Which sessions", selection: Binding(
                    get: { team.transcriptChoices.mode },
                    set: { mode in Task { await team.setTranscriptMode(mode) } })) {
                    Text("All recent sessions").tag(TeamTranscriptChoices.Mode.all)
                    Text("Only the ones I pick").tag(TeamTranscriptChoices.Mode.chosen)
                }
                if team.transcriptChoices.mode == .chosen {
                    if team.recentTranscripts.isEmpty {
                        Text("No sessions in the transcript window yet — they appear after the next publish.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(team.recentTranscripts) { session in
                        Toggle(isOn: Binding(get: { team.transcriptChoices.chosen.contains(session.id) },
                                             set: { on in Task { await team.setTranscript(session.id, shared: on) } })) {
                            Text("\(session.project) · \(session.lastDay)")
                        }
                        .controlSize(.small)
                    }
                }
            }
            Text("Applies from the next publish. Re-share re-wraps the last 30 days of stats and sessions, and the transcripts still on this Mac (the local copies are capped at 1 GB).")
                .font(.caption).foregroundStyle(.secondary)
            Button("Re-share last 30 days…") { reshareConfirm = true }
                .confirmationDialog("Re-share the last 30 days?", isPresented: $reshareConfirm) {
                    Button("Re-share") { Task { await team.reshare(days: 30) } }
                    Button("Cancel", role: .cancel) {}
                }
            Text("Nobody keeps a kind on this Mac entirely. Live state off makes you look offline to the team; stats off leaves you out of the leaders' totals.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Team session control (#220 §7.1): grants, the add sheet, the feed.
    private func controlSection(_ snap: TeamSnapshot) -> some View {
        Section("Session control") {
            if team.grants.grants.isEmpty {
                Text("Nobody can drive your sessions.").foregroundStyle(.secondary)
            }
            ForEach(team.grants.grants) { g in
                HStack {
                    Text("\(audienceLabel(g.audience, snap)) · \(sessionsLabel(g.sessions)) · \(g.capabilities.sorted().joined(separator: ", "))")
                    Spacer()
                    Button("Remove") { Task { await team.revokeGrant(id: g.id) } }.controlSize(.small)
                }
            }
            Button("Add grant…") { showGrant = true }
            Text("A grant lets the people named send prompts, answer tool prompts or switch modes on the sessions named — from their Mac or `infinitusctl`. Every command is logged below.")
                .font(.caption).foregroundStyle(.secondary)
            if !feed.lines.isEmpty {
                DisclosureGroup("Recent commands") {
                    ForEach(feed.lines.suffix(50).reversed()) { line in
                        HStack {
                            Text(line.text).font(.caption)
                            Spacer()
                            Text(line.at, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    /// §5.4: the leader's Cloudflare token (a secret, never shown back), a
    /// hostname per member under `<label>.<zone>`, orphans deletable.
    private func hostnamesSection(_ snap: TeamSnapshot) -> some View {
        Section("Hostnames") {
            if team.cloudflareConfigured, let ledger = team.hostnames {
                HStack {
                    Text("Cloudflare zone \(ledger.zone) · label \(ledger.label)")
                    Spacer()
                    Button("Forget token") { Task { await team.forgetCloudflare() } }.controlSize(.small)
                }
                ForEach(snap.members) { m in
                    HStack {
                        Text(m.name)
                        Spacer()
                        if let host = team.hostname(of: m.kid) {
                            Text(host).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else {
                            Button("Give hostname") { Task { await team.giveHostname(kid: m.kid) } }.controlSize(.small)
                        }
                    }
                }
                let orphans = team.roster.map { ledger.orphans(roster: $0.doc) } ?? []
                if !orphans.isEmpty {
                    Text("Orphaned").font(.caption).foregroundStyle(.secondary)
                    ForEach(orphans, id: \.kid) { o in
                        HStack {
                            Text(o.record.hostname).font(.caption)
                            Spacer()
                            Button("Delete", role: .destructive) { Task { await team.deleteHostname(kid: o.kid) } }.controlSize(.small)
                        }
                    }
                }
            } else {
                TextField("Zone", text: $cfZone, prompt: Text("example.com"))
                TextField("Label", text: $cfLabel, prompt: Text(TeamHostnames.defaultLabel))
                SecureField("Cloudflare API token", text: $cfToken, prompt: Text("Account: Cloudflare Tunnel Edit · Zone: DNS Edit"))
                Button("Save") {
                    let token = cfToken
                    cfToken = ""
                    Task { await team.saveCloudflare(zone: cfZone, label: cfLabel, token: token) }
                }
                .disabled(cfZone.isEmpty || cfLabel.isEmpty || cfToken.isEmpty)
                if let count = team.hostnames?.records.count, count > 0 {
                    Text("\(count) hostname\(count == 1 ? "" : "s") minted earlier; paste the token again to manage them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("A hostname is a Cloudflare named tunnel under your zone (`<name>.<label>.<zone>`), minted per member; their Mac starts it on the next fetch and keeps the same address across restarts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func audienceLabel(_ t: TeamRoster.ShareTarget, _ snap: TeamSnapshot) -> String {
        switch t {
        case .off: "nobody"
        case .leaders: "leaders"
        case .team: "whole team"
        case .members(let kids): kids.map { kid in snap.members.first { $0.kid == kid }?.name ?? String(kid.prefix(8)) }.joined(separator: ", ")
        }
    }

    private func sessionsLabel(_ s: TeamGrants.Sessions) -> String {
        switch s {
        case .all: "all sessions"
        case .some(let ids): ids.count == 1 ? "1 session" : "\(ids.count) sessions"
        }
    }

    private var exclusionsSection: some View {
        Section("Excluded projects") {
            ForEach(team.exclusions.projects, id: \.self) { p in
                HStack {
                    Text(p).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Include again") { Task { await team.setExcluded(p, on: false) } }.buttonStyle(.link)
                }
            }
            Button("Exclude a folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { Task { await team.setExcluded(url.path, on: true) } }
            }
            Text("Nothing from an excluded folder — stats, sessions, transcripts — leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: helpers

    /// Spec §7 catch-up: a session bigger than one pass's read slice
    /// takes several passes. The last report carries what is left; whole
    /// megabytes, from a published value — nothing here ticks.
    private var catchUp: String? {
        let bytes = team.lastReport?.remainingBytes ?? 0
        guard bytes > 0 else { return nil }
        return "catching up, \(max(1, Int((Double(bytes) / 1_048_576).rounded()))) MB to go"
    }

    /// The busy label plus how far the publisher is through this Mac's
    /// transcript sources — "Publishing… pushing 3/12 · catching up, 640
    /// MB to go". The background loop sets no busy label, so a big
    /// publish shows progress alone (and never disables the form:
    /// `.disabled` stays on `busy`).
    private var statusLine: String? {
        let phase = team.progress.map { "\($0.phase == "push" ? "pushing" : "reading") \($0.done)/\($0.total)" }
        let line: String?
        switch (team.busy, phase) {
        case let (busy?, phase?): line = "\(busy) \(phase)"
        case let (busy?, nil): line = busy
        case let (nil, phase?): line = "Publishing… \(phase)"
        case (nil, nil): line = nil
        }
        guard let line else { return nil }
        return catchUp.map { "\(line) · \($0)" } ?? line
    }

    private func kindTitle(_ kind: String) -> String {
        switch kind {
        case TeamKinds.stats: "Stats"
        case TeamKinds.now: "Live state"
        case TeamKinds.sessions: "Session index"
        case TeamKinds.transcripts: "Transcripts"
        case TeamKinds.crashes: "Crash summaries"
        case TeamKinds.fleet: "Fleet"
        default: kind
        }
    }

    private func sharedKinds() -> String {
        ListFormatter.localizedString(byJoining: TeamKinds.memberKinds.map { kindTitle($0).lowercased() })
    }

    private func audienceTag(_ t: TeamRoster.ShareTarget) -> String {
        switch t {
        case .off: "off"
        case .leaders: "leaders"
        case .team: "team"
        case .members(let kids): kids.first.map { "kid:\($0)" } ?? "leaders"
        }
    }

    private func audience(from tag: String, _ snap: TeamSnapshot) -> TeamRoster.ShareTarget {
        if tag == "off" { return .off }
        if tag == "team" { return .team }
        if tag.hasPrefix("kid:") { return .members([String(tag.dropFirst(4))]) }
        return .leaders
    }

    private func relative(_ at: Int?) -> String {
        guard let at else { return "never" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(at)), relativeTo: Date())
    }

    static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size); image.addRepresentation(rep)
        return image
    }

    private func share(_ text: String) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [text])
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }
}
