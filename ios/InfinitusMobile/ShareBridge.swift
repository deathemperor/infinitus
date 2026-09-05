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
    ///
    /// Multi-host (04-phone): the extension reaches ONE machine, so the
    /// bridge carries the primary host's record. `host` is nil only
    /// before the first pairing (or in fixture mode), and then there is
    /// nothing worth bridging — the legacy single-host defaults keys
    /// stopped being written when `mirror_hosts` took over.
    @MainActor
    static func publish(host: MirrorHost?, _ defaults: UserDefaults = .standard) {
        guard let host else { return }
        let pairing = Pairing(
            endpoints: host.endpoints,
            lastGood: host.lastGood,
            token: host.normalizedToken,
            deviceId: NetworkFleetMirror.deviceId,
            deviceName: NetworkFleetMirror.deviceName)
        guard pairing != lastWritten, let data = try? JSONEncoder().encode(pairing) else { return }
        let status = SharedKeychain.write(service: service, account: account, data: data)
        guard status == errSecSuccess else {
            log.error("share bridge write failed: \(status)")
            return
        }
        lastWritten = pairing
        log.notice("share bridge: \(pairing.endpoints.count) routes, token \(pairing.token.isEmpty ? "none" : "****", privacy: .public)")
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
}
