import Foundation
import InfinitusCore

/// Several Macs per phone (#144 phase 1): one `MacPairing` per OTHER
/// paired Mac — the primary stays in `NetworkFleetMirror`'s own
/// UserDefaults keys, so nothing about it changes. The add-vs-replace
/// and swap decisions are pure Core (`MirrorPairing.Others`, tested
/// there); this is just the phone-side storage.
typealias MacPairing = MirrorPairing.MacPairing

extension MacPairing {
    static let othersKey = "mirror_other_macs"

    static func load(_ defaults: UserDefaults = .standard) -> [MacPairing] {
        guard let data = defaults.data(forKey: othersKey) else { return [] }
        return (try? JSONDecoder().decode([MacPairing].self, from: data)) ?? []
    }

    static func save(_ list: [MacPairing], _ defaults: UserDefaults = .standard) {
        defaults.set((try? JSONEncoder().encode(list)) ?? Data(), forKey: othersKey)
    }
}
