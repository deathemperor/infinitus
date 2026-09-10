import Foundation

/// The Cloudflare quick tunnel that fronts the T3 Code fork server's
/// port (#572 N2). `fork_tunnel_enabled` / `fork_server_port` in the
/// Devices prefs drive it; the `status` reply carries this under
/// `forkTunnel` so the fork's pairing QR can carry the public URL —
/// off-LAN pairing is the fork's own QR with this hostname, and T3
/// Connect stays disabled. The port is wherever the fork's server bound:
/// it scans up from 3773 when that one is taken, so the server writes
/// the pref on startup rather than native guessing.
public struct ForkTunnelStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// `fork_tunnel_enabled` is off.
        case off
        /// `fork_server_port` is outside 1...65535.
        case invalidPort
        /// A playground or mock instance never opens a public door.
        case blocked
        /// cloudflared is not installed on this Mac.
        case unavailable
        /// cloudflared is running and has not printed its hostname yet.
        case starting
        /// The tunnel answers at `url`.
        case up
        /// cloudflared exited on its own while the toggle is still on.
        case stopped
    }

    /// T3's starting port; the server scans upward from it.
    public static let defaultPort = 3773
    public static func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    public let enabled: Bool
    public let port: Int
    public let state: State
    /// `https://<hostname>` while up — the form the fork's
    /// `buildPairingUrl` takes.
    public let url: String?
    /// The bare hostname while up.
    public let hostname: String?

    public init(enabled: Bool, port: Int, state: State, url: String?) {
        self.enabled = enabled; self.port = port; self.state = state; self.url = url
        self.hostname = url.map { $0.replacingOccurrences(of: "https://", with: "") }
    }

    /// The state from what the app knows, first reason wins: the toggle,
    /// the port, whether this instance may expose anything, whether
    /// cloudflared exists, then the child's own life.
    public static func derive(enabled: Bool, port: Int, allowed: Bool, available: Bool,
                              running: Bool, url: String?) -> ForkTunnelStatus {
        let state: State
        if !enabled { state = .off }
        else if !isValidPort(port) { state = .invalidPort }
        else if !allowed { state = .blocked }
        else if !available { state = .unavailable }
        else if url != nil { state = .up }
        else if running { state = .starting }
        else { state = .stopped }
        return ForkTunnelStatus(enabled: enabled, port: port, state: state, url: state == .up ? url : nil)
    }
}
