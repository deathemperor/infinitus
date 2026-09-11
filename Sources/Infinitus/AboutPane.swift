import SwiftUI
import AppKit
import InfinitusCore

/// The app's own release channel. The app never self-replaces: a Homebrew
/// install checks what `brew upgrade` WOULD install (the tap's cask file)
/// and hands off to brew; a source or zip install just gets the GitHub
/// release check.
@MainActor
final class AppReleaseModel: ObservableObject {
    @Published var latest: String? { didSet { onLatest?(latest) } }
    @Published var updateAvailable = false
    @Published var status: String?
    /// Popup hook: the version string when newer, nil otherwise.
    var onUpdate: ((String?) -> Void)?
    /// Mirror hook (#121): fires with whatever `latest` found, newer or
    /// not, so the phone can compare its own version against it.
    var onLatest: ((String?) -> Void)?
    private static let api = URL(
        string: "https://api.github.com/repos/deathemperor/infinitus/releases/latest")!
    private static let nightlyAPI = URL(
        string: "https://api.github.com/repos/deathemperor/infinitus/releases/tags/nightly")!
    private static let caskURL = URL(
        string: "https://raw.githubusercontent.com/deathemperor/homebrew-tap/main/Casks/infinitus.rb")!
    private let defaults = AppDefaults.standard

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
    var nightly: Bool { defaults.string(forKey: "update_channel") == "nightly" }

    /// Launch + every 6h: check when a day has passed — same cadence as
    /// the engine's own checker; the popup chip is what surfaces it.
    func startAutoCheck() {
        Task { [weak self] in
            while !Task.isCancelled {
                if let self {
                    let last = self.defaults.double(forKey: "app_update_last_check")
                    if Date().timeIntervalSince1970 - last > 24 * 3600 {
                        await self.check()
                    }
                }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                if self == nil { return }
            }
        }
    }

    func check() async {
        status = "checking…"
        updateAvailable = false
        struct Release: Decodable {
            let tag_name: String
            let name: String?
        }
        do {
            if nightly {
                let (data, resp) = try await fetch(Self.nightlyAPI)
                if resp == 404 { status = "no nightly published yet"; return }
                let release = try JSONDecoder().decode(Release.self, from: data)
                latest = release.tag_name
                // Rolling tag — no version to compare; show what's current.
                status = "latest: \(release.name ?? "nightly") — reinstall to update"
                defaults.set(Date().timeIntervalSince1970, forKey: "app_update_last_check")
                onUpdate?(nil)
                return
            }
            let tag: String
            let via: String
            if BrewUpdater.channel == .stable {
                let (data, _) = try await fetch(Self.caskURL)
                let rb = String(decoding: data, as: UTF8.self)
                guard let m = rb.firstMatch(of: #/version "([^"]+)"/#) else {
                    status = "could not read the cask version"; return
                }
                tag = String(m.1); via = "via Homebrew"
            } else {
                let (data, resp) = try await fetch(Self.api)
                if resp == 404 {
                    status = "no releases published yet — this build came from source"
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                tag = release.tag_name.hasPrefix("v")
                    ? String(release.tag_name.dropFirst()) : release.tag_name
                via = "on GitHub"
            }
            latest = tag
            defaults.set(Date().timeIntervalSince1970, forKey: "app_update_last_check")
            if let a = PackageVersion(currentVersion), let b = PackageVersion(tag), a < b {
                updateAvailable = true
                status = "\(tag) is available \(via)"
            } else {
                status = "up to date (latest: \(tag))"
            }
            onUpdate?(updateAvailable ? tag : nil)
        } catch {
            status = "release check failed: \(error.localizedDescription)"
        }
    }

    private func fetch(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Homebrew awareness (user 2026-08-30: "release to homebrew, updates
/// should be from it too"). Channel detection is a Caskroom lookup; the
/// upgrade itself is `brew upgrade/reinstall --cask` — brew swaps the
/// bundle at a new inode, so the running process survives until relaunch.
@MainActor
final class BrewUpdater: ObservableObject {
    /// Raw value is the phone's `app.updateChannel` label (#121).
    enum Channel: String { case source, stable, nightly }
    @Published var running = false
    @Published var status: String?
    /// The app wires this to AppModel.relaunchApp, which waits for this
    /// pid to exit before `open` and quits the way the menu does: a bare
    /// terminate(nil) from a Task parks a team member in
    /// applicationShouldTerminate's nested loop (#654, the #673 lesson).
    var relaunch: () -> Void = { NSApplication.shared.terminate(nil) }

    static let brewPath: String? =
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }

    static let channel: Channel = {
        // A dev build (unbundled, or built into the repo) must never
        // read the Caskroom as "this process came from brew" — only the
        // /Applications copy is the cask's.
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              let brew = brewPath else { return .source }
        let caskroom = URL(fileURLWithPath: brew)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Caskroom")
        let fm = FileManager.default
        if fm.fileExists(atPath: caskroom.appendingPathComponent("infinitus@nightly").path) {
            return .nightly
        }
        if fm.fileExists(atPath: caskroom.appendingPathComponent("infinitus").path) {
            return .stable
        }
        return .source
    }()

    var channelLabel: String {
        switch Self.channel {
        case .source: return "source build"
        case .stable: return "Homebrew"
        case .nightly: return "Homebrew (nightly)"
        }
    }

    /// Uninstall this track's cask, install the other one, relaunch.
    /// The casks conflict_with each other, so the order matters.
    func move(toNightly: Bool) {
        guard !running, let brew = Self.brewPath else { return }
        let fromCask = toNightly ? "infinitus" : "infinitus@nightly"
        let toCask = toNightly ? "infinitus@nightly" : "infinitus"
        run(brew: brew, steps: [["uninstall", "--cask", fromCask],
                                ["install", "--cask", toCask]],
            doing: "switching to \(toCask)…")
    }

    /// Runs the brew command, then relaunches into the replaced bundle.
    func upgrade() {
        guard !running, let brew = Self.brewPath else { return }
        let args = Self.channel == .nightly
            ? ["reinstall", "--cask", "infinitus@nightly"]
            : ["upgrade", "--cask", "infinitus"]
        run(brew: brew, steps: [args], doing: "brew \(args.joined(separator: " "))…")
    }

    private func run(brew: String, steps: [[String]], doing: String) {
        running = true
        status = doing
        Task.detached {
            var ok = true
            var tail = ""
            for args in steps {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: brew)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                try? p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                tail = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n").suffix(2).joined(separator: " · ")
                if p.terminationStatus != 0 { ok = false; break }
            }
            let done = ok
            let detail = tail
            await MainActor.run { [weak self] in
                self?.running = false
                if done {
                    self?.status = "done — relaunching…"
                    self?.relaunch()
                } else {
                    self?.status = "brew failed: \(detail)"
                }
            }
        }
    }
}

/// About + updates: hero card (icon, version, build, tagline), a Software
/// Update group, full-row link rows with leading icons and a trailing
/// arrow, and a license footer.
struct AboutPane: View {
    @ObservedObject var appRelease: AppReleaseModel
    /// Shared with the phone's `/app/update` route (#121) so the two
    /// never run two upgrades at once.
    @ObservedObject var brew: BrewUpdater
    @AppStorage("update_channel", store: AppDefaults.standard) private var updateChannel = "stable"
    @Environment(\.openURL) private var openURL

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
    private var appBuild: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    /// Stamped nowhere in Info.plist, so read the truth: the executable's
    /// modification time IS the build time.
    private var buildDate: String? {
        guard let url = Bundle.main.executableURL,
              let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate
        else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 5) {
                    appMark
                        .padding(.bottom, 6)
                    Text("Infinitus").font(.title2).bold()
                    Text(appBuild.map { "Version \(appVersion) (\($0))" }
                         ?? "Version \(appVersion)")
                        .foregroundStyle(.secondary)
                    if let buildDate {
                        Text("Built \(buildDate)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Every Claude account in one menu bar — swap before you stall.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                LabeledContent {
                    HStack {
                        if appRelease.updateAvailable, BrewUpdater.channel == .stable {
                            Button("Update via Homebrew") { brew.upgrade() }
                                .disabled(brew.running)
                                .buttonStyle(.borderedProminent)
                        } else if BrewUpdater.channel == .nightly {
                            Button("Reinstall the Latest Nightly") { brew.upgrade() }
                                .disabled(brew.running)
                        }
                        Button(appRelease.status == nil ? "Check for Updates…" : "Check Again") {
                            Task { await appRelease.check() }
                        }
                    }
                } label: {
                    Text("Infinitus \(appVersion) · \(brew.channelLabel)")
                    if let s = brew.status ?? appRelease.status {
                        Text(s).font(.caption)
                            .foregroundStyle(appRelease.updateAvailable ? Color.orange : .secondary)
                    }
                }
                Picker("Channel", selection: $updateChannel) {
                    Text("Stable").tag("stable")
                    Text("Nightly").tag("nightly")
                }
                .pickerStyle(.segmented)
                .onChange(of: updateChannel) { Task { await appRelease.check() } }
                if BrewUpdater.channel == .stable, updateChannel == "nightly" {
                    Button("Switch the Install to Nightly") {
                        brew.move(toNightly: true)
                    }
                    .disabled(brew.running)
                } else if BrewUpdater.channel == .nightly, updateChannel == "stable" {
                    Button("Switch the Install Back to Stable") {
                        brew.move(toNightly: false)
                    }
                    .disabled(brew.running)
                }
            } header: {
                Text("Software Update")
            } footer: {
                Text("A Homebrew install updates through Homebrew — Infinitus "
                     + "never replaces itself. Builds from source and zip "
                     + "installs get the release check only.")
            }
            .settingsAnchor("About/Software Update")

            Section {
                LabeledContent("Delivery") {
                    Text(Notifier.lastAuthError == nil
                         ? "Notification Center"
                         : "Scripted (Notification Center unavailable)")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text(Notifier.lastAuthError == nil
                     ? "Alerts arrive as system notifications, so Notification "
                       + "Center's own settings decide how they look."
                     : "Notification Center turned this build down, so alerts "
                       + "are delivered as scripted pop-ups instead — they "
                       + "still arrive. A Developer ID signature, or one Xcode "
                       + "run with automatic signing, restores system "
                       + "notifications.")
            }
            .settingsAnchor("About/Notifications")

            Section("Links") {
                linkRow("chevron.left.forwardslash.chevron.right", "GitHub",
                        "https://github.com/deathemperor")
                linkRow("globe", "Website", "https://huuloc.com")
                linkRow("shippingbox", "Project — Infinitus",
                        "https://github.com/deathemperor/infinitus")
            }
            .settingsAnchor("About/Links")

            Section {
                Text("Infinitus by deathemperor · MIT License")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }

    /// The real Infinitus icon EVERYWHERE (user 2026-08-30): bundled runs
    /// have it as the app icon; unbundled runs (run-unbundled.sh) pull it
    /// from the built Infinitus.app on disk (bundle id lookup, then the
    /// repo's known path). The glyph-on-gradient card remains only as the
    /// final fallback when no built bundle exists at all.
    @ViewBuilder private var appMark: some View {
        if let icon = Self.infinitusIcon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.42, green: 0.20, blue: 0.95),
                                 Color(red: 0.07, green: 0.05, blue: 0.20)],
                        startPoint: .topLeading, endPoint: .bottom))
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white.opacity(0.15))
                    )
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                Image(nsImage: MenuBarGlyph.image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .foregroundStyle(.white)
            }
        }
    }

    static var infinitusIcon: NSImage? {
        if Bundle.main.bundlePath.hasSuffix(".app"),
           let icon = NSApp.applicationIconImage {
            return icon
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = ["death/infinitus/Infinitus.app", "death/limitless/Infinitus.app"]
            .map { home.appendingPathComponent($0).path }
        for id in ["run.infinitus", "com.huuloc.infinitus", "com.huuloc.limitless"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                candidates.insert(url.path, at: 0)
                break
            }
        }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 64, height: 64)
            return icon
        }
        return nil
    }

    private func linkRow(_ symbol: String, _ title: String, _ url: String) -> some View {
        Button {
            if let u = URL(string: url) { openURL(u) }
        } label: {
            HStack {
                Image(systemName: symbol)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint("Opens in your browser.")
    }
}

extension AboutPane {
    static let searchEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(pane: "About", section: "Software Update", label: "Channel",
                            keywords: ["update", "channel", "stable", "nightly", "homebrew", "upgrade"],
                            anchor: "About/Software Update"),
        SettingsSearchEntry(pane: "About", section: "Notifications", label: "Delivery",
                            keywords: ["notification", "delivery", "banner", "alerts"],
                            anchor: "About/Notifications"),
        SettingsSearchEntry(pane: "About", section: "Links", label: "Links",
                            keywords: ["github", "website", "project", "license", "version"],
                            anchor: "About/Links"),
    ]
}
