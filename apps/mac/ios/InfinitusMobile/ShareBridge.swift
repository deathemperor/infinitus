import Foundation
import InfinitusCore
import os

/// The pairing the share extension (#64) needs to reach the Mac — routes,
/// token, device identity — as one keychain item both bundles open
/// through the shared access group (SharedKeychain). The app writes it;
/// the extension reads it.
/// Sessions are not bridged: the app is backgrounded most of the time,
/// so the extension asks the Mac for the live list instead.
enum ShareBridge {
    struct Pairing: Codable, Equatable {
        var endpoints: [String]
        var lastGood: String?
        var token: String
        var deviceId: String
        var deviceName: String
        /// The other paired Macs (#144), reached by the extension through
        /// their own mirrors; absent in items written before it knew them.
        var others: [MacPairing]?
    }

    static let service = "run.infinitus.share"
    static let account = "pairing"
    /// Set only in the extension's defaults: `UIDevice.current.name` is
    /// the bare model name inside an extension, and the Mac's connected
    /// devices list takes the name from every request.
    static let deviceNameKey = "mirror_device_name"
    private static let log = Logger(subsystem: "run.infinitus.mobile", category: "share")
    private static var lastWritten: Pairing?

    /// The app's side: called after every refresh and pairing change,
    /// writes only when something changed.
    @MainActor
    static func publish(_ defaults: UserDefaults = .standard) {
        let pairing = Pairing(
            endpoints: NetworkFleetMirror.storedEndpoints(defaults),
            lastGood: defaults.string(forKey: NetworkFleetMirror.lastGoodKey),
            token: MirrorPairing.normalize(defaults.string(forKey: NetworkFleetMirror.tokenKey) ?? ""),
            deviceId: NetworkFleetMirror.deviceId,
            deviceName: NetworkFleetMirror.deviceName,
            others: MacPairing.load(defaults))
        guard pairing != lastWritten, let data = try? JSONEncoder().encode(pairing) else { return }
        let status = SharedKeychain.write(service: service, account: account, data: data)
        guard status == errSecSuccess else {
            log.error("share bridge write failed: \(status)")
            return
        }
        lastWritten = pairing
        log.notice("share bridge: \(pairing.endpoints.count) routes, token \(pairing.token.isEmpty ? "none" : "****", privacy: .public), \(pairing.others?.count ?? 0) other Macs")
    }

    /// The extension's side: copies the bridged pairing into the
    /// extension's own defaults under the keys NetworkFleetMirror reads,
    /// so the mirror client runs unchanged and the Mac sees the same
    /// device. False when the app never paired (or has no saved route —
    /// the extension does not browse Bonjour).
    static func adopt(into defaults: UserDefaults = .standard) -> Bool {
        guard let data = SharedKeychain.read(service: service, account: account),
              let pairing = try? JSONDecoder().decode(Pairing.self, from: data),
              !pairing.endpoints.isEmpty else { return false }
        defaults.set(pairing.endpoints, forKey: NetworkFleetMirror.manualKey)
        defaults.set(pairing.lastGood, forKey: NetworkFleetMirror.lastGoodKey)
        defaults.set(pairing.token, forKey: NetworkFleetMirror.tokenKey)
        defaults.set(pairing.deviceId, forKey: NetworkFleetMirror.deviceIdKey)
        defaults.set(pairing.deviceName, forKey: deviceNameKey)
        return true
    }

    /// A suggestions-row conversation names one session on one Mac
    /// (#144): the primary's by cwd alone — what every donation was
    /// before other Macs existed — another Mac's as "mac:<id>\u{1F}<cwd>"
    /// (the unit separator: a pairing id is a UUID, a path never holds it).
    static func conversation(macId: String?, cwd: String) -> String {
        macId.map { "mac:\($0)\u{1F}\(cwd)" } ?? cwd
    }

    static func session(conversation: String) -> (macId: String?, cwd: String) {
        guard conversation.hasPrefix("mac:"), let cut = conversation.firstIndex(of: "\u{1F}") else {
            return (nil, conversation)
        }
        let id = conversation[conversation.index(conversation.startIndex, offsetBy: 4)..<cut]
        return (String(id), String(conversation[conversation.index(after: cut)...]))
    }

    /// The extension's side too: the other paired Macs, each reached
    /// through `NetworkFleetMirror(pairing:)` rather than the defaults.
    static func others() -> [MacPairing] {
        guard let data = SharedKeychain.read(service: service, account: account),
              let pairing = try? JSONDecoder().decode(Pairing.self, from: data) else { return [] }
        return pairing.others ?? []
    }
}
