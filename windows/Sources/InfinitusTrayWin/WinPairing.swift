import Foundation
import InfinitusCore
import WinSDK

/// The pairing URL the tray copies, and the clipboard call that delivers
/// it. Token storage matches the daemon's
/// (`windows/Sources/InfinitusWin/WinPairingStore.swift`) file for file —
/// duplicated rather than shared because SwiftPM can't import one
/// executable target into another, and the two must agree byte for byte
/// or the phone would pair against a token the daemon doesn't hold.
enum WinPairing {
    static let defaultMirrorPort: UInt16 = 47824

    static var tokenPath: URL {
        let roaming = ProcessInfo.processInfo.environment["APPDATA"]
            ?? "\(NSHomeDirectory())\\AppData\\Roaming"
        return URL(fileURLWithPath: roaming)
            .appendingPathComponent("Infinitus")
            .appendingPathComponent("pair-token")
    }

    /// The stored token, or nil. The tray never CREATES one: minting a
    /// token here would leave the daemon serving a different secret than
    /// the URL just copied. `infinitus-win pair` owns creation.
    static func token() -> String? {
        guard let raw = try? String(contentsOf: tokenPath, encoding: .utf8) else { return nil }
        let normalized = MirrorPairing.normalize(raw)
        return normalized.isEmpty ? nil : normalized
    }

    /// `infinitus://pair?url=…&token=…` for this box's LAN and tailnet
    /// addresses, or nil when there is no token yet or no usable address.
    static func pairingURL(port: UInt16 = defaultMirrorPort) -> String? {
        guard let token = token() else { return nil }
        let addresses = WinAddresses.ipv4()
        var endpoints: [String] = []
        if let lan = MirrorPairing.lanAddress(in: addresses) {
            endpoints.append("http://\(lan):\(port)")
        }
        if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
            endpoints.append("http://\(tailnet):\(port)")
        }
        guard !endpoints.isEmpty else { return nil }
        return MirrorPairing.pairURL(endpoints: endpoints, token: token)
    }

    /// Puts Unicode text on the clipboard. On success the clipboard owns
    /// the memory — freeing it after `SetClipboardData` succeeds would be
    /// a double free.
    @discardableResult
    static func setClipboardText(_ text: String) -> Bool {
        let units = Array(text.utf16) + [0]
        let bytes = units.count * MemoryLayout<WCHAR>.size
        guard let handle = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)) else { return false }
        guard let buffer = GlobalLock(handle) else {
            GlobalFree(handle)
            return false
        }
        units.withUnsafeBytes { source in
            if let base = source.baseAddress { memcpy(buffer, base, bytes) }
        }
        GlobalUnlock(handle)
        guard OpenClipboard(nil) else {
            GlobalFree(handle)
            return false
        }
        defer { CloseClipboard() }
        EmptyClipboard()
        guard SetClipboardData(UINT(CF_UNICODETEXT), handle) != nil else {
            GlobalFree(handle)
            return false
        }
        return true
    }
}
