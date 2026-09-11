import Foundation

/// The registration-level kill switch (#115 item 4): a tool's own
/// `enabled: false` cannot help when the hang precedes its config read,
/// so the entries leave `settings.json` — parked under
/// `infinitusDisabledHooks`, with a timestamped backup beside the file.
public enum HookKillSwitch {
    public static let parkedKey = "infinitusDisabledHooks"

    /// Moves every hook whose command belongs to `owner` out of `hooks`
    /// into `infinitusDisabledHooks[owner]`. Returns the new object and
    /// how many commands moved.
    public static func disable(owner: String, in settings: [String: Any],
                               source: HookRegistration.Source = .user) -> (settings: [String: Any], moved: Int) {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return (settings, 0) }
        var parked = (settings[parkedKey] as? [String: Any]) ?? [:]
        var mine = (parked[owner] as? [String: Any]) ?? [:]
        var moved = 0
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var keep: [[String: Any]] = []
            var park: [[String: Any]] = []
            for group in groups {
                let commands = (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
                let owned = commands.filter { HookInventory.owner(of: $0, source: source).name == owner }
                if owned.isEmpty { keep.append(group); continue }
                if owned.count == commands.count {
                    park.append(group); moved += owned.count
                } else {
                    // A mixed group: split it, keep the others' hooks in place.
                    var kept = group; var parkedGroup = group
                    kept["hooks"] = (group["hooks"] as? [[String: Any]] ?? []).filter { HookInventory.owner(of: $0["command"] as? String ?? "", source: source).name != owner }
                    parkedGroup["hooks"] = (group["hooks"] as? [[String: Any]] ?? []).filter { HookInventory.owner(of: $0["command"] as? String ?? "", source: source).name == owner }
                    keep.append(kept); park.append(parkedGroup); moved += owned.count
                }
            }
            if keep.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = keep }
            if !park.isEmpty { mine[event] = ((mine[event] as? [[String: Any]]) ?? []) + park }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        if !mine.isEmpty { parked[owner] = mine }
        if !parked.isEmpty { settings[parkedKey] = parked }
        return (settings, moved)
    }

    /// Puts a parked tool's hooks back.
    public static func restore(owner: String, in settings: [String: Any]) -> (settings: [String: Any], moved: Int) {
        var settings = settings
        guard var parked = settings[parkedKey] as? [String: Any],
              let mine = parked[owner] as? [String: Any] else { return (settings, 0) }
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var moved = 0
        for (event, value) in mine {
            guard let groups = value as? [[String: Any]] else { continue }
            hooks[event] = ((hooks[event] as? [[String: Any]]) ?? []) + groups
            moved += groups.reduce(0) { $0 + (($1["hooks"] as? [[String: Any]])?.count ?? 0) }
        }
        settings["hooks"] = hooks
        parked.removeValue(forKey: owner)
        if parked.isEmpty { settings.removeValue(forKey: parkedKey) } else { settings[parkedKey] = parked }
        return (settings, moved)
    }

    public static func parkedOwners(in settings: [String: Any]) -> [String] {
        ((settings[parkedKey] as? [String: Any]) ?? [:]).keys.sorted()
    }

    /// Rewrites `settings.json` in place through a backup
    /// (`settings.json.infinitus-<stamp>.bak`) and an atomic replace.
    @discardableResult
    public static func apply(_ transform: ([String: Any]) -> ([String: Any], Int),
                             to url: URL, fm: FileManager = .default, now: Date = Date()) throws -> (backup: URL, moved: Int) {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HookKillSwitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings.json is not an object"])
        }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backup = url.appendingPathExtension("infinitus-\(stamp).bak")
        try data.write(to: backup)
        let (updated, moved) = transform(object)
        let out = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        // Foundation's atomic write is a temp file + rename on both
        // Darwin and Linux; replaceItemAt is Darwin-only in practice.
        try out.write(to: url, options: .atomic)
        return (backup, moved)
    }
}
