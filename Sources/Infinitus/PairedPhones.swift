import Foundation
import InfinitusCore

/// The phones this Mac has served, kept across relaunches (Settings ›
/// Devices › Phones). Fed by every authenticated request; Forget drops
/// the record — the phone comes back on its next request while the
/// pairing token is shared, so Forget is housekeeping, not revocation.
@MainActor
final class PairedPhoneStore: ObservableObject {
    static let key = "paired_phones"
    @Published private(set) var phones: [PairedPhone] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            phones = (try? decoder.decode([PairedPhone].self, from: data)) ?? []
        }
    }

    func record(_ client: MirrorClient) {
        let merged = PairedPhones.merge(client, into: phones)
        phones = merged.list
        if merged.changed { persist() }
    }

    func forget(id: String) {
        phones = PairedPhones.forget(id: id, in: phones)
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try? encoder.encode(phones), forKey: Self.key)
    }
}
