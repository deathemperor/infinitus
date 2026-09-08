import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InfinitusCore

/// Devices: the phone companion and its routes, plus settings sync across
/// Macs (iCloud, file). Was "Sync" — it lived in Display before, which is
/// the wrong home (user report 2026-08-30): it syncs notify flags and
/// engine config too, not just display prefs.
struct SyncPane: View {
    @ObservedObject var sync: SettingsSyncModel
    @ObservedObject var app: AppModel
    /// The LAN server publishes its own state (port, failures), so the
    /// pane observes it directly — AppModel doesn't republish it.
    @ObservedObject private var server: MirrorServer
    /// The quick tunnel publishes its URL the same way — the QR list
    /// grows a third entry the moment cloudflared names the hostname.
    @ObservedObject private var tunnel: QuickTunnel
    @ObservedObject private var named: NamedTunnel
    @ObservedObject private var pusher: LiveActivityPusher
    /// Typed hostname/token live here until Save: the model restarts the
    /// tunnel on a hostname change, and a half-typed one shouldn't.
    @State private var namedHost = ""
    @State private var namedToken = ""
    /// The token is masked until asked for: settings panes get shared in
    /// screenshots, and this one is a read key.
    @State private var revealToken = false
    /// Tailscale coming up (or going away) changes nothing the models
    /// publish — the utun address just appears. Re-probe while the pane
    /// is up so the status row and the route list follow it.
    @State private var tailscale = TailscaleStatus.notInstalled
    /// Open until every step is ticked; closes itself once paired.
    @State private var walkthroughOpen = true
    /// The secondary addresses stay folded: one scan pairs every route,
    /// so the other two are for typing by hand, which is rare.
    @State private var otherAddressesOpen = false
    /// Regenerating un-pairs every phone, so it asks (the alert itself
    /// lands with the crash-report pass; the button sets this).
    @State private var confirmRegenerate = false
    /// The crash report whose Delete is being confirmed. Lives here, not
    /// on CrashReportsSection, so the dialog can sit on the Form.
    @State private var confirmCrashDelete: CrashReport?
    /// Forgetting a keychain secret is hard to undo (the APNs .p8 downloads
    /// from Apple once), so both Forget buttons ask first.
    @State private var confirmForgetKey = false
    @State private var confirmForgetToken = false
    private let reprobe = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    init(sync: SettingsSyncModel, app: AppModel) {
        self.sync = sync
        self.app = app
        _server = ObservedObject(wrappedValue: app.mirrorServer)
        _tunnel = ObservedObject(wrappedValue: app.quickTunnel)
        _named = ObservedObject(wrappedValue: app.namedTunnel)
        _pusher = ObservedObject(wrappedValue: app.liveActivityPusher)
    }

    var body: some View {
        Form {
            // The phone companion's transport (#9): this Mac serves its
            // last fleet snapshot to InfinitusMobile — on the LAN, over a
            // tailnet, or through a throwaway Cloudflare tunnel. No
            // backend of ours anywhere; the pairing token is the lock.
            walkthrough
            Section {
                Toggle("Serve the fleet to my phone", isOn: $app.mirrorLANEnabled)
                if let status = server.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Pairing token") {
                    HStack(spacing: 8) {
                        Text(revealToken ? app.mirrorPairToken
                             : MirrorPairing.mask(app.mirrorPairToken))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                        Button("Copy") { copy(app.mirrorPairToken) }
                        Button("Regenerate\u{2026}") { confirmRegenerate = true }
                    }
                }
                TextField("This Mac's name", text: $app.machineNameOverride,
                          prompt: Text(MachineName.system()))
                if app.mirrorLANEnabled {
                    if app.pairRoutes.isEmpty {
                        Text("Waiting for the listener to come up\u{2026}")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            if let image = PairQR.image(for: app.pairURL) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 110, height: 110)
                                    .padding(4)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .accessibilityLabel("Pairing QR code")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                if let primary = app.pairRoutes.first {
                                    addressRow(primary)
                                }
                                Button("Copy Pair Link") { copy(app.pairURL) }
                                if let primary = app.pairRoutes.first {
                                    // #151: Linux/Windows open this in a browser.
                                    Button("Copy Browser Link") {
                                        copy(MirrorWebClient.url(endpoint: primary.endpoint, token: app.mirrorPairToken))
                                    }
                                    .help("The sessions and chat page for a machine without the Infinitus app; the pairing token is in the link.")
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        if app.pairRoutes.count > 1 {
                            DisclosureGroup("Other addresses", isExpanded: $otherAddressesOpen) {
                                ForEach(app.pairRoutes.dropFirst()) { route in
                                    addressRow(route)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("The phone scans the code once and keeps every address in it, trying "
                     + "them in order \u{2014} so a tunnel address that changes on restart "
                     + "falls through to Wi-Fi or Tailscale. Every request must carry the "
                     + "pairing token; the snapshot it answers with carries account names, "
                     + "emails and usage estimates, never tokens or push secrets.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // The Tunnel group below shows once this Mac is serving — the
            // gate the old "Pair a phone" section opened, re-opened here.
            if app.mirrorLANEnabled {
                Section {
                    tailscaleRow
                    if QuickTunnel.binaryPath != nil {
                        Toggle("Expose through a Cloudflare quick tunnel",
                               isOn: $app.mirrorTunnelEnabled)
                        if let status = tunnel.status {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Publish the current URL to infinitus.run",
                               isOn: $app.mirrorRendezvousEnabled)
                            .disabled(!app.mirrorTunnelEnabled)
                        namedTunnelRows
                    } else {
                        LabeledContent("Cloudflare quick tunnel") {
                            Button("Copy Install Command") { copy("brew install cloudflared") }
                        }
                        Text("Not installed. Paste the copied command into Terminal and a "
                             + "toggle appears here to reach this Mac through a random "
                             + "public address \u{2014} no Cloudflare account needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Tunnel")
                } footer: {
                    Text("Same Wi-Fi needs none of this. From anywhere, pick one: Tailscale "
                         + "on both devices, a quick tunnel (a random public address that "
                         + "changes every start), or your own Cloudflare tunnel (a hostname "
                         + "that never changes). The pairing token is what keeps the "
                         + "snapshot private in every case. Publishing the current address "
                         + "to infinitus.run stores only a hash of the token and the "
                         + "address, so a paired phone finds the new one instead of "
                         + "rescanning.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .onAppear { probeTailscale(); namedHost = app.mirrorNamedTunnelHost }
                .onReceive(reprobe) { _ in probeTailscale() }
            }
            CrashReportsSection(app: app, confirmDelete: $confirmCrashDelete)
            Section {
                liveActivityRows
            } header: {
                Text("Phone lock screen")
            } footer: {
                Text("The phone's Live Activities (working sessions, revival countdown) "
                     + "update while the app is open. To keep them live with the app "
                     + "closed, this Mac pushes through Apple (APNs) with a key from "
                     + "your developer account: Certificates, Identifiers & Profiles \u{2192} "
                     + "Keys \u{2192} + \u{2192} Apple Push Notifications service, download the .p8.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Sync settings via iCloud Drive", isOn: $sync.enabled)
                if let status = sync.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Display preferences, custom themes and engine settings travel through "
                     + "one file in your iCloud Drive. Never credentials, never push "
                     + "secrets. The last Mac to write wins.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Manual path for machines outside the iCloud account
            // (user request 2026-08-30). Same snapshot, same scope.
            Section {
                LabeledContent("Settings as a file") {
                    HStack {
                        Button("Export\u{2026}") { runExportPanel() }
                        Button("Import\u{2026}") { runImportPanel() }
                    }
                }
            } header: {
                Text("File")
            } footer: {
                Text("The same settings the iCloud sync carries \u{2014} display "
                     + "preferences, custom themes and engine settings. Never "
                     + "credentials, never push secrets.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Regenerate the pairing token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { app.regeneratePairToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every phone paired with this Mac stops working until it scans the new "
                 + "code. Nothing else changes \u{2014} this Mac keeps serving, and one "
                 + "scan pairs a phone again.")
        }
        .confirmationDialog("Delete this crash report?",
                            isPresented: Binding(get: { confirmCrashDelete != nil },
                                                 set: { if !$0 { confirmCrashDelete = nil } }),
                            presenting: confirmCrashDelete) { report in
            Button("Delete", role: .destructive) {
                app.removeCrash(report.id)
                confirmCrashDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmCrashDelete = nil }
        } message: { report in
            Text("The report from \(crashWhen(report)) is gone from this Mac for good. The "
                 + "crash it describes has already happened \u{2014} deleting it changes "
                 + "nothing else.")
        }
        .confirmationDialog("Forget the push key?", isPresented: $confirmForgetKey) {
            Button("Forget", role: .destructive) { pusher.storeKey(pem: "") }
            Button("Keep Key", role: .cancel) { }
        } message: {
            Text("The key leaves the keychain and lock-screen activities stop updating "
                 + "with the app closed. Apple hands out each key file once, so without "
                 + "your own copy you'll need a new key to set push up again. Pairing "
                 + "and everything else here are untouched.")
        }
        .confirmationDialog("Forget the tunnel token?", isPresented: $confirmForgetToken) {
            Button("Forget", role: .destructive) { app.saveNamedTunnelToken("") }
            Button("Keep Token", role: .cancel) { }
        } message: {
            Text("The token leaves the keychain. Unless Cloudflare's config file on this "
                 + "Mac already routes this hostname, the tunnel stops now and phones reach "
                 + "this Mac by its other routes only. Paste the token from the Cloudflare "
                 + "dashboard again to bring it back \u{2014} the hostname stays saved.")
        }
    }

    // MARK: - Walkthrough

    /// One step of "Set up your phone": live state, not a static how-to.
    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        let done: Bool
    }

    /// The restart-proof remote route: a Cloudflare tunnel the user owns.
    /// Cloudflare holds the hostname → localhost:port mapping; this Mac
    /// holds only the tunnel token, in the keychain.
    /// Live Activity pushes (APNs): the .p8 key that lets this Mac keep
    /// the phone's lock-screen activities moving with the app closed.
    @ViewBuilder private var liveActivityRows: some View {
        TextField("Team ID", text: $pusher.teamID, prompt: Text("ABCDE12345"))
        TextField("Key ID", text: $pusher.keyID, prompt: Text("the key's 10-character id"))
        HStack {
            Button(pusher.keyStored ? "Replace Key from Clipboard" : "Paste Key from Clipboard") {
                pusher.storeKey(pem: NSPasteboard.general.string(forType: .string) ?? "")
            }
            if pusher.keyStored {
                Button("Forget Key\u{2026}", role: .destructive) { confirmForgetKey = true }
            }
            Text(pusher.keyStored ? "In the Keychain" : "Not Set Up")
                .font(.caption).foregroundStyle(.secondary)
        }
        if pusher.registrations.isEmpty {
            Text("No phone has registered a push token yet — open the app once "
                 + "on the phone after it's paired.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(pusher.registrations.values.sorted { $0.registeredAt > $1.registeredAt },
                    id: \.slot) { reg in
                Text("\(reg.deviceName) · \(reg.kind.rawValue) · \(reg.environment) · "
                     + reg.registeredAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let result = pusher.lastResult {
            Text(result).font(.caption).foregroundStyle(.secondary)
        }
        Stepper(value: $app.liveActivityRateSeconds, in: 0...60, step: 5) {
            Text(app.liveActivityRateSeconds == 0
                 ? "tok/min: pushed with other changes only"
                 : "tok/min: pushed every \(app.liveActivityRateSeconds) s")
        }
    }

    /// Who is talking to the mirror (user 2026-09-03: "show active/
    /// connected devices"): one row per phone, green while it has been
    /// heard from inside MirrorClient.activeWindow, grey after.
    private var connectedDevices: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected devices").font(.caption.weight(.semibold))
                ForEach(server.clients) { client in
                    let active = client.isActive(now: context.date)
                    HStack(spacing: 6) {
                        Circle().fill(active ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(client.name)
                        Text("· \(client.route) · \(relative(client.lastSeen, now: context.date))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder private var namedTunnelRows: some View {
        Toggle("Expose through your own Cloudflare tunnel",
               isOn: $app.mirrorNamedTunnelEnabled)
        TextField("Hostname", text: $namedHost, prompt: Text("infinitus.example.com"))
            .textFieldStyle(.roundedBorder)
            .onSubmit { app.mirrorNamedTunnelHost = namedHost }
        if app.namedTunnelLocalConfig {
            LabeledContent("Tunnel token") {
                Text("Not needed \u{2014} Cloudflare's config file on this Mac already "
                     + "routes this hostname.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            SecureField("Tunnel token", text: $namedToken,
                        prompt: Text(app.namedTunnelTokenPresent
                                     ? "•••••••• (stored in keychain)" : "eyJh… from the Cloudflare dashboard"))
                .textFieldStyle(.roundedBorder)
        }
        HStack {
            Button("Save Tunnel") {
                app.mirrorNamedTunnelHost = namedHost
                if !namedToken.isEmpty { app.saveNamedTunnelToken(namedToken) }
                namedToken = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(NamedTunnel.normalizeHostname(namedHost).isEmpty)
            if app.namedTunnelTokenPresent {
                Button("Forget Token\u{2026}", role: .destructive) { confirmForgetToken = true }
            }
        }
        if let status = named.status {
            Text(status).font(.caption)
                .foregroundStyle(named.connected ? Color.secondary : Color.orange)
        }
        if app.mirrorNamedTunnelEnabled, let port = server.port,
           port != MirrorTransport.defaultPort {
            Text("This Mac is listening on port \(port), not \(MirrorTransport.defaultPort) — "
                 + "the tunnel's public hostname in the Cloudflare dashboard must point at "
                 + "http://localhost:\(port).")
                .font(.caption).foregroundStyle(.orange)
        }
        Text("Both ways need a Cloudflare account with your domain on it. In the "
             + "dashboard: Zero Trust \u{2192} Networks \u{2192} Tunnels \u{2192} Create "
             + "\u{2192} Cloudflared, name it, paste its token above, and point its public "
             + "hostname at this Mac's port \(MirrorTransport.defaultPort). In Terminal: "
             + "create and route a tunnel with cloudflared, add this hostname to its config "
             + "file, and no token is needed here.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Copy the Config File Path") { copy("~/.cloudflared/config.yml") }
            Spacer()
        }
    }

    private var steps: [Step] {
        let serving = app.mirrorLANEnabled && server.port != nil
        let routes = app.pairRoutes
        let remote = routes.contains { $0.id != "lan" }
        return [
            Step(id: 1, title: "Serve the fleet to my phone",
                 detail: "The toggle below. This Mac answers with its fleet "
                       + "snapshot; nothing leaves the machine otherwise.",
                 done: serving),
            Step(id: 2, title: "Put Infinitus on the phone",
                 detail: "The iOS companion is in the repo under ios/ (build "
                       + "it in Xcode until it reaches TestFlight).",
                 done: server.lastServed != nil),
            Step(id: 3, title: "Pick how the phone reaches this Mac",
                 detail: remote
                    ? "Same Wi-Fi works already; a remote route is up too."
                    : "Same Wi-Fi needs nothing. From anywhere: Tailscale "
                      + "on both devices, your own Cloudflare tunnel (stable "
                      + "hostname), or a quick tunnel (see Tunnel below).",
                 done: !routes.isEmpty),
            Step(id: 4, title: "Scan the QR from the phone",
                 detail: "On the phone: Settings → Mac connection → Scan QR, "
                       + "pointing at Pairing below — one QR carries "
                       + "every route.",
                 done: server.lastServed != nil),
        ]
    }

    private var walkthrough: some View {
        let steps = self.steps
        let doneCount = steps.filter(\.done).count
        return Section {
            DisclosureGroup(isExpanded: $walkthroughOpen) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "\(step.id).circle")
                            .foregroundStyle(step.done ? .green : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).strikethrough(step.done, color: .secondary)
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                if !server.clients.isEmpty {
                    connectedDevices
                }
                // Hand the rest to an agent (user 2026-09-02): the same
                // state as the checklist, plus the exact commands, as one
                // pasteable brief. The token rides along only while it's
                // revealed above — a masked pane copies a masked brief.
                HStack {
                    Button("Copy for an AI Agent") { copy(agentBrief(steps)) }
                    Text(revealToken
                         ? "Includes the pairing token."
                         : "Token left out — Reveal it below to include it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                LabeledContent("Set up your phone") {
                    Text(doneCount == steps.count ? "all set" : "\(doneCount) of \(steps.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { walkthroughOpen = doneCount < steps.count }
    }

    /// Markdown a coding agent can act on: what's done, what's left, and
    /// the commands for each remaining step. Everything here is derived
    /// from the live state so it never disagrees with the checklist.
    private func agentBrief(_ steps: [Step]) -> String {
        let routes = app.pairRoutes
        let token = revealToken ? app.mirrorPairToken
            : "<hidden — in Infinitus: Settings → Devices → Pairing token → Reveal/Copy>"
        let port = server.port.map(String.init) ?? "?"
        var out = ["# Infinitus — set up the phone companion (agent brief)",
                   "Generated by Infinitus on \(Host.current().localizedName ?? "this Mac") "
                   + "at \(Date().formatted(date: .abbreviated, time: .shortened)). "
                   + "Source: https://github.com/deathemperor/infinitus", "",
                   "## State"]
        for step in steps { out.append("- [\(step.done ? "x" : " ")] \(step.id). \(step.title)") }
        out.append("- Listener: \(app.mirrorLANEnabled ? "on, port \(port)" : "off")")
        for r in routes { out.append("- Route \"\(r.title)\": \(r.endpoint)") }
        out.append("- Pairing token: \(token)")
        out.append("- Tailscale on this Mac: \(tailscaleLine)")
        out.append("- cloudflared on this Mac: \(QuickTunnel.binaryPath ?? "not installed")")
        out += ["", "## Do the unticked steps, in order",
                "1. Serving: a toggle in the Infinitus menu bar app (Settings → Devices → "
                + "\"Serve the fleet to my phone\"). No shell equivalent — ask the user to flip it.",
                "2. Phone app: the iOS companion lives in ios/ of the repo. From a clone:",
                "   cd ios && xcodegen generate",
                "   xcrun devicectl list devices            # find the phone's UDID",
                "   xcodebuild -project InfinitusMobile.xcodeproj -scheme InfinitusMobile "
                + "-configuration Debug -destination 'id=<UDID>' -derivedDataPath build "
                + "-allowProvisioningUpdates DEVELOPMENT_TEAM=<team id> CODE_SIGN_STYLE=Automatic build",
                "   xcrun devicectl device install app --device <UDID> "
                + "build/Build/Products/Debug-iphoneos/InfinitusMobile.app",
                "   (a free personal team works; the user trusts the profile once on the phone)",
                "3. A route. Same Wi-Fi needs nothing. From anywhere, either:",
                "   - Tailscale: `brew install --cask tailscale-app` (the pkg asks for an admin "
                + "password — the user types it), open Tailscale, sign in; on the phone install "
                + "Tailscale from the App Store and sign into the same tailnet. Infinitus shows "
                + "the tailnet route by itself.",
                "   - Cloudflare quick tunnel: `brew install cloudflared`, then in Infinitus "
                + "Settings → Devices → Tunnel turn on the tunnel (random public URL that "
                + "changes every Infinitus start — a phone with no other route rescans after a "
                + "restart; the token is the only lock).",
                "   - Cloudflare named tunnel (stable hostname, the user's own domain on "
                + "Cloudflare): `cloudflared tunnel login` (the user authorizes the zone in the "
                + "browser), `cloudflared tunnel create infinitus`, `cloudflared tunnel route dns "
                + "infinitus <host>`, then write ~/.cloudflared/config.yml with `tunnel: <id>`, "
                + "`credentials-file: ~/.cloudflared/<id>.json`, and an ingress entry "
                + "`hostname: <host>` → `service: http://localhost:\(MirrorTransport.defaultPort)` "
                + "plus a final `service: http_status:404`. In Infinitus Settings → Devices → "
                + "Tunnel enter <host> under \"your own Cloudflare tunnel\" and turn it on — no "
                + "token needed; Infinitus runs `cloudflared tunnel run` itself.",
                "4. Pair: on the phone, Settings → Mac connection → Scan QR, pointing at "
                + "Infinitus Settings → Devices → Pairing (one QR carries every route). "
                + "Or enter a route address and the pairing token by hand in the same screen.",
                "", "## Verify",
                "curl -s -o /dev/null -w '%{http_code}\\n' -H 'Authorization: Bearer <token>' "
                + "http://<host>:\(port)/snapshot   # 200 = paired route works; 401 = wrong token",
                "Infinitus ticks step 4 the moment the phone fetches with the right token."]
        return out.joined(separator: "\n")
    }

    private var tailscaleLine: String {
        switch tailscale {
        case .notInstalled: return "not installed"
        case .installed: return "installed, not connected"
        case .connected(let ip): return "connected, \(ip)"
        }
    }

    private func probeTailscale() {
        let now = TailscaleStatus.probe(addresses: LocalAddresses.ipv4())
        if now != tailscale { tailscale = now }
    }

    /// Guide, don't install: see TailscaleStatus.
    @ViewBuilder
    private var tailscaleRow: some View {
        switch tailscale {
        case .notInstalled:
            LabeledContent("Tailscale") {
                Button("Get Tailscale…") { NSWorkspace.shared.open(TailscaleStatus.downloadURL) }
            }
            Text("Free for personal use. Install it here and on the phone, "
                 + "sign both into the same tailnet, and a Tailscale route "
                 + "appears under Pairing by itself \u{2014} reachable from "
                 + "anywhere, no port forwarding, no public URL.")
                .font(.caption).foregroundStyle(.secondary)
        case .installed(let app):
            LabeledContent("Tailscale") {
                if app.pathExtension == "app" {
                    Button("Open Tailscale") {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init())
                    }
                } else {
                    Text("Installed, not connected").font(.caption)
                }
            }
            Text("Installed but not connected \u{2014} open it and sign in; the "
                 + "route shows up under Pairing once it is.")
                .font(.caption).foregroundStyle(.secondary)
        case .connected(let ip):
            LabeledContent("Tailscale") {
                Text("Connected \u{00B7} \(ip)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("The Tailscale route is under Pairing. The phone needs "
                 + "Tailscale too, signed into the same tailnet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One route: its name, its address, and a Copy that says what it
    /// copies. `PairRoute.title` is already the human name ("On this
    /// Wi-Fi", "Anywhere via Tailscale").
    private func addressRow(_ route: PairRoute) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(route.title).font(.callout).bold()
            HStack {
                Text(route.endpoint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button { copy(route.endpoint) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy the \(route.title) address")
                    .help("Copy the \(route.title) address.")
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func runExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "infinitus-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.export(to: url) }
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await sync.importConfig(from: url) }
    }
}

/// How a crash report is named in a sentence: the moment it happened.
private func crashWhen(_ report: CrashReport) -> String {
    report.at.formatted(date: .abbreviated, time: .shortened)
}

/// Crashes of the phone app (MetricKit, over the mirror) and of this
/// Mac app (its own diagnostic reports): built-in, nothing leaves the
/// machine. Each can go into a session's chat for triage.
private struct CrashReportsSection: View {
    @ObservedObject var app: AppModel
    @Binding var confirmDelete: CrashReport?

    var body: some View {
        Section {
            if app.crashReports.isEmpty {
                Text("None. The phone reports its own crashes here on its next launch; "
                     + "this Mac's land here after a relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(app.crashReports.prefix(10)) { report in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.summary).lineLimit(1)
                        Text("\(report.at.formatted(date: .abbreviated, time: .shortened)) · app \(report.appVersion) · \(report.osVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let sessions = app.liveSessions?.sessions ?? []
                    Menu("Send to Session") {
                        if sessions.isEmpty { Text("No live sessions") }
                        ForEach(sessions, id: \.pid) { s in
                            Button("\(app.sessionProgress.byPid[s.pid]?.name ?? URL(fileURLWithPath: s.cwd).lastPathComponent) · \(s.status)") {
                                app.sendCrash(report, toPid: s.pid)
                            }
                        }
                    }
                    .fixedSize()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.transcript, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy the report from \(crashWhen(report))")
                    .help("Copy the report.")
                    Button(role: .destructive) { confirmDelete = report } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete the report from \(crashWhen(report))")
                    .help("Delete this report from this Mac.")
                }
            }
        } header: {
            Text("Crash reports")
        } footer: {
            Text("Nothing leaves this Mac. Send one into a live session to have it looked "
                 + "at, or copy it to read yourself.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
