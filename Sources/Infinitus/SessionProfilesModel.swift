import Foundation
import InfinitusCore

/// The Mac's saved session profiles (#165): one JSON file under App
/// Support, read once at launch, written on every change. The mirror
/// snapshot carries the list to the phone.
@MainActor
final class SessionProfilesModel: ObservableObject {
    @Published private(set) var profiles: [SessionProfile]
    let url: URL
    @Published var lastError: String?

    /// `INFINITUS_PROFILES`: the e2e gate's own file, so its round-trips
    /// never touch the real list.
    init(url: URL = ProcessInfo.processInfo.environment["INFINITUS_PROFILES"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Infinitus/session-profiles.json")) {
        self.url = url
        self.profiles = SessionProfiles.load(from: url)
    }

    func set(_ profile: SessionProfile) {
        write(SessionProfiles.upsert(profile, into: profiles))
    }

    func remove(_ name: String) {
        write(SessionProfiles.removing(name, from: profiles))
    }

    /// Rename keeps the row's position; a name already taken is refused.
    func rename(_ name: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = profiles.firstIndex(where: { SessionProfiles.same($0.name, name) }) else { return false }
        guard !profiles.contains(where: { SessionProfiles.same($0.name, trimmed) && !SessionProfiles.same($0.name, name) })
        else { return false }
        var next = profiles
        next[i].name = trimmed
        write(next)
        return true
    }

    private func write(_ next: [SessionProfile]) {
        do {
            try SessionProfiles.save(next, to: url)
            profiles = next
            lastError = nil
        } catch {
            lastError = "couldn't save profiles: \(error.localizedDescription)"
        }
    }
}
