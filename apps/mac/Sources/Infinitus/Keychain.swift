import Foundation
import Security

/// The keychain slots: CLIProxyAPI's management key (#8) — generic
/// password, service = bundle-id-scoped, account = the proxy base URL,
/// so two proxies could hold two keys — and the Cloudflare named-tunnel
/// token (#9), same shape under its own service. Never mirrored into
/// defaults.
enum Keychain {
    static let service = "run.infinitus.cliproxy"
    static let tunnelService = "run.infinitus.cloudflare-tunnel"
    /// 9Router's dashboard password (third engine), account = base URL.
    static let nineRouterService = "run.infinitus.9router"
    /// The APNs auth key (.p8) for Live Activity pushes, account = key id.
    static let apnsService = "run.infinitus.apns"
    /// Team secrets (spec §2.1 local path): the identity secret and one
    /// store token per team, account = the TeamSecrets name. Binary
    /// values travel base64 in the generic-password slot.
    static let teamService = "run.infinitus.team"

    static func readData(account: String, service: String) -> Data? {
        read(account: account, service: service).flatMap { Data(base64Encoded: $0) }
    }

    static func writeData(account: String, value: Data, service: String) -> Bool {
        write(account: account, value: value.base64EncodedString(), service: service)
    }

    static func read(account: String, service: String = Self.service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Never block launch on an access prompt (an unsigned dev
            // build hits one every rebuild): no grant = no key, and the
            // pane says "enter the key" instead.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(account: String, value: String, service: String = Self.service) -> Bool {
        delete(account: account, service: service)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Attributes-only lookup (no `kSecReturnData`): does not touch the
    /// decrypt ACL, so it answers "is there an item?" even when `read`
    /// would return nil for a denied grant.
    static func exists(account: String, service: String = Self.service) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String, service: String = Self.service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
