import SwiftUI
import InfinitusCore

/// File-based settings sync through iCloud Drive (SyncSnapshot has the
/// scope and the why-not-KVS note). One file, deterministic tick, last
/// writer wins with remote preferred:
///   remote changed since last seen → pull; local drifted → push;
///   otherwise remember what we saw. Runs on the snapshot refresh tick,
/// so "eventual" is at most one refresh interval behind.
@MainActor
final class SettingsSyncModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "icloud_sync")
            if enabled {
                Task { await tick() }
            } else {
                lastSeen = nil
            }
        }
    }

    private var lastSeen: SyncSnapshot?
    /// Account names (`icloud_sync_names`): the file's names were applied
    /// here since the option came on. Until then this Mac's own rows —
    /// mostly blanks on a Mac that never named anything — must not reach
    /// the file, or the first push after flipping it on would clear every
    /// other Mac's names.
    private var namesAdopted = false
    /// Names an engine refused (`rename` threw), by key: this Mac reports
    /// the file's value for them instead of its own, so a Mac that cannot
    /// wear a name does not push its old one back and fight the file
    /// every tick.
    private var refusedNames: [String: String] = [:]
    private let defaults = AppDefaults.standard
    private weak var model: AppModel?

    /// Display prefs that travel. Per-machine state (pinned popup, debug
    /// menu, update bookkeeping, the sync toggle itself) stays home.
    static let boolKeys: Set<String> = [
        "show_account_name", "title_scoped", "title_remaining", "title_icon_only",
        "compact_rows", "footer_actions_hidden",
        "sort_headroom",
        "push_all_dead", "push_last_alive",
    ]
    static let intKeys: Set<String> = ["refresh_interval", "revive_lead_minutes"]
    static let doubleKeys: Set<String> = ["glass_focused"]
    static let stringKeys: Set<String> = [
        "title_pct", "title_reset", "gamification_style", "popup_layout", "popup_text_size",
        "burn_style",
    ]
    static var appKeys: Set<String> {
        boolKeys.union(intKeys).union(doubleKeys).union(stringKeys)
    }

    init() {
        enabled = AppDefaults.standard.bool(forKey: "icloud_sync")
    }

    func attach(model: AppModel) { self.model = model }

    nonisolated static func containerDir(home: String = NSHomeDirectory()) -> URL? {
        let drive = URL(fileURLWithPath:
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("Infinitus")
    }

    /// Dev, mock and playground instances never touch the shared file:
    /// a mock-mode debug binary pushed the DEMO engine's config into it
    /// and the real app pulled it, unsetting the user's threshold and
    /// strategy (2026-09-03 "my cswap config kept getting reverted").
    static var isDevInstance: Bool {
        ProcessInfo.processInfo.environment["INFINITUS_CONTROL_SOCKET"] != nil
            || ProcessInfo.processInfo.environment["INFINITUS_SWAPD_CLI"] != nil
            || AppDefaults.standard.bool(forKey: "mock_mode")
            || Bundle.main.bundleIdentifier == nil
    }

    func tick() async {
        guard enabled, !Self.isDevInstance else { return }
        guard let dir = Self.containerDir() else { return }
        let url = dir.appendingPathComponent("settings-sync.json")
        let remote = (try? Data(contentsOf: url)).flatMap(SyncSnapshot.decode)
        let namesOn = defaults.bool(forKey: "icloud_sync_names")
        if !namesOn { namesAdopted = false; refusedNames = [:] }
        if namesOn, !namesAdopted {
            // The file's names are the truth when the option comes on.
            // The rows still show the old aliases until the next refresh,
            // so comparing now would push them back: let the next tick
            // read the renamed fleet.
            if let remote { await applyNames(remote.names) }
            namesAdopted = true
            return
        }
        let local = await localSnapshot(names: namesOn)
        // Re-check after the await: a stale in-flight tick must not push
        // under an off toggle (observed as "pushed 00:23", 2026-08-30).
        guard enabled else { return }
        if let remote, remote != lastSeen, remote != local {
            // Remote moved (another Mac wrote, or first tick over an
            // existing file): adopt it. Remote wins a two-sided race — the
            // file IS the shared truth. Except the ENGINE keys on the
            // first tick after launch: this Mac's cswap is the truth for
            // its own settings, and a relaunch used to pull whatever the
            // file last held over a `cswap config set` made meanwhile.
            let first = lastSeen == nil
            await apply(remote, engine: !first)
            if first, remote.engine != local.engine {
                // Push the merge (remote prefs + this engine) next tick.
                lastSeen = SyncSnapshot(app: remote.app, themes: remote.themes, engine: local.engine, names: remote.names)
            } else {
                lastSeen = remote
            }
        } else if remote != local {
            // A failed push leaves lastSeen alone, so the next tick
            // retries; nothing draws the outcome since the Settings
            // window retired.
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
                try local.encoded().write(to: url)
                lastSeen = local
            } catch {}
        } else if lastSeen == nil {
            lastSeen = remote
        }
    }

    private func localSnapshot(names namesOn: Bool) async -> SyncSnapshot {
        var app: [String: JSONValue] = [:]
        // Only explicitly-set keys travel; on the other side absent keys
        // are left alone, so factory defaults never overwrite a choice.
        for key in Self.appKeys where defaults.object(forKey: key) != nil {
            if Self.boolKeys.contains(key) {
                app[key] = .bool(defaults.bool(forKey: key))
            } else if Self.intKeys.contains(key) {
                app[key] = .number(Double(defaults.integer(forKey: key)))
            } else if Self.doubleKeys.contains(key) {
                app[key] = .number(defaults.double(forKey: key))
            } else if let s = defaults.string(forKey: key) {
                app[key] = .string(s)
            }
        }
        // Names: the file's map with this Mac's rows over it; with the
        // option off the map passes through untouched, so a Mac that does
        // not sync names never erases the ones the others share.
        var names = lastSeen?.names ?? [:]
        if namesOn, let model {
            for fleet in model.fleets where fleet.capabilities.contains(.rename) {
                names = SyncNames.merge(names, local: SyncNames.rows(provider: fleet.provider, accounts: fleet.accounts))
            }
            names = SyncNames.merge(names, local: refusedNames)
        }
        // Engine settings rode along as `cswap config` text; the Mac
        // stops filling the field until a `swapd config` port (#756).
        return SyncSnapshot(app: app, themes: RowTheme.loadCustom(), engine: [:], names: names)
    }

    /// Rename this Mac's accounts to the file's names, awaited, so the
    /// engine holds them before the next refresh reads the fleet. A
    /// refusal lands on the popup's error line like a hand rename's.
    private func applyNames(_ names: [String: String]) async {
        guard let model else { return }
        for fleet in model.fleets where fleet.capabilities.contains(.rename) {
            let renames = SyncNames.pendingRenames(names: names, provider: fleet.provider, accounts: fleet.accounts)
            for (number, alias) in renames.sorted(by: { $0.key < $1.key }) {
                guard let account = fleet.accounts.first(where: { $0.number == number }) else { continue }
                let key = SyncNames.key(provider: fleet.provider, email: account.email)
                do {
                    _ = try await fleet.engine.rename(fleet: fleet.provider, number: number, alias)
                    refusedNames[key] = nil
                    model.reorderError = nil
                } catch {
                    refusedNames[key] = alias
                    model.reorderError = EngineFailure.sentence(error)
                }
            }
        }
    }

    private func apply(_ snap: SyncSnapshot, engine applyEngine: Bool = true) async {
        for (key, value) in snap.app where Self.appKeys.contains(key) {
            switch value {
            case .bool(let b): defaults.set(b, forKey: key)
            case .number(let n):
                if Self.doubleKeys.contains(key) { defaults.set(n, forKey: key) }
                else { defaults.set(Int(n), forKey: key) }
            case .string(let s): defaults.set(s, forKey: key)
            default: break
            }
        }
        model?.reloadPrefs()
        if defaults.bool(forKey: "icloud_sync_names") { await applyNames(snap.names) }
        if snap.themes != RowTheme.loadCustom() {
            try? RowTheme.saveCustom(snap.themes)
            model?.reloadCustomThemes()
        }
    }
}
