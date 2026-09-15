import Foundation
import WebKit

/// One-time copy-migration for the rename (Limitless → Infinitus,
/// 2026-08-30): the App Support dir and the iCloud Drive folder move to
/// the new name; the old ones are left in place for rollback, the same
/// way the CswapBar → Limitless move was done. Per item, not per dir:
/// run-unbundled.sh (and a cache write) can create the new dir before
/// this runs, and a whole-dir check would then skip themes.json forever.
enum RenameMigration {
    static func run(home: String = NSHomeDirectory()) {
        copyMissingItems(
            from: "\(home)/Library/Application Support/Limitless",
            to: "\(home)/Library/Application Support/Infinitus")
        copyMissingItems(
            from: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Limitless",
            to: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/Infinitus")
    }

    private static func copyMissingItems(from old: String, to new: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: old) else { return }
        for name in items where !name.hasPrefix("Limitless-unbundled") {
            let dst = "\(new)/\(name)"
            guard !fm.fileExists(atPath: dst) else { continue }
            do {
                try fm.createDirectory(atPath: new, withIntermediateDirectories: true)
                try fm.copyItem(atPath: "\(old)/\(name)", toPath: dst)
                NSLog("Infinitus: migrated \(name) from \(old)")
            } catch {
                NSLog("Infinitus: migration of \(name) failed: \(error)")
            }
        }
    }
}

/// The sign-in flow's per-account "private window" (retired 2026-09-14)
/// kept one WKWebsiteDataStore per account plus a shared Google jar,
/// each holding login cookies nothing reads any more. Removed once,
/// after the two defaults keys that named them are dropped.
///
/// Order matters twice (alpha.13 crashed at every launch on a Mac that
/// had signed in through that window): `remove(forIdentifier:)` on a
/// process that has created no WebKit object yet dispatches onto a run
/// loop WebKit has not set up and segfaults, so `default()` is touched
/// first to initialize it; and the keys go before the removals, so a
/// launch that dies in the middle leaves orphaned stores on disk
/// instead of running the same cleanup, and dying the same way, on
/// every launch after.
enum PrivateWindowCleanup {
    static let mapKey = "auth_web_store_map"
    static let googleJarKey = "auth_web_store_google"

    @MainActor static func run(defaults: UserDefaults = AppDefaults.standard) {
        let map = defaults.dictionary(forKey: mapKey) as? [String: String] ?? [:]
        let ids = (Array(map.values) + [defaults.string(forKey: googleJarKey)].compactMap { $0 })
            .compactMap(UUID.init)
        guard !ids.isEmpty else { return }
        defaults.removeObject(forKey: mapKey)
        defaults.removeObject(forKey: googleJarKey)
        _ = WKWebsiteDataStore.default()
        Task { @MainActor in
            for id in ids {
                try? await WKWebsiteDataStore.remove(forIdentifier: id)
            }
            NSLog("Infinitus: removed \(ids.count) retired sign-in web store(s)")
        }
    }
}
