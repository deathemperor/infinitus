import Foundation
import AppKit

/// Runs `cloudflared tunnel run` for a dashboard-managed Cloudflare
/// tunnel (#9 remote access, the stable route): the user creates the
/// tunnel once in Zero Trust (Networks → Tunnels → Cloudflared), points
/// its public hostname at `http://localhost:47824` there, and pastes the
/// tunnel token here. Unlike the quick tunnel the hostname is theirs and
/// never changes, so a phone paired to it survives every restart.
///
/// Two ways to hold the credentials, both invisible to argv:
///  - dashboard-managed: the tunnel token in the keychain
///    (`Keychain.tunnelService`, account = the hostname), handed to
///    cloudflared as `TUNNEL_TOKEN` in the environment;
///  - locally-managed: `cloudflared tunnel login/create/route dns` done
///    on this Mac, `~/.cloudflared/config.yml` naming the hostname in its
///    ingress — then `cloudflared tunnel run` needs nothing from us.
@MainActor
final class NamedTunnel: ObservableObject {
    /// Whether cloudflared has at least one edge connection registered —
    /// the moment the hostname actually answers.
    @Published private(set) var connected = false
    @Published private(set) var status: String?
    /// Set by AppModel so tunnel events land in the popup's event log.
    var log: ((String, String) -> Void)?

    static let hostnameKey = "mirror_named_tunnel_host"
    static let enabledKey = "mirror_named_tunnel_enabled"
    private static let pidKey = "mirror_named_tunnel_pid"

    private var process: Process?
    private(set) var hostname = ""

    var isRunning: Bool { process != nil }

    init() {
        reapOrphan()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
    }

    /// `infinitus.example.com` from whatever the user typed — a pasted
    /// `https://…/` included. Empty when there's nothing usable.
    static func normalizeHostname(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        guard !host.isEmpty, host.contains("."),
              host.unicodeScalars.allSatisfy(allowed.contains) else { return "" }
        return host
    }

    /// The phone's endpoint for this route — TLS is Cloudflare's.
    var endpoint: String? { connected ? "https://\(hostname)" : nil }

    /// True when `~/.cloudflared/config.yml` routes this hostname — the
    /// locally-managed setup, which needs no token from the keychain.
    static func localConfigCovers(_ hostname: String,
                                  home: String = NSHomeDirectory()) -> Bool {
        guard !hostname.isEmpty,
              let text = try? String(contentsOfFile: home + "/.cloudflared/config.yml",
                                     encoding: .utf8) else { return false }
        return text.lowercased().contains("hostname: \(hostname)")
    }

    /// True when `~/.cloudflared/config.yml` has an ingress rule sending
    /// `hostname` to `localhost:<port>` (#650: the fork's second rule on
    /// the companion's tunnel). T3 scans up from 3773 when that port is
    /// taken, so a rule baked to the wrong port is the realistic silent
    /// break — the service line right after the hostname must name it.
    static func localConfigRoutes(_ hostname: String, toPort port: Int,
                                  home: String = NSHomeDirectory()) -> Bool {
        guard !hostname.isEmpty,
              let text = try? String(contentsOfFile: home + "/.cloudflared/config.yml",
                                     encoding: .utf8) else { return false }
        let lines = text.lowercased().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(where: { $0.hasPrefix("- hostname: \(hostname)") || $0 == "hostname: \(hostname)" }),
              i + 1 < lines.count else { return false }
        let service = lines[i + 1]
        return service.hasPrefix("service:")
            && (service.hasSuffix("localhost:\(port)") || service.hasSuffix("127.0.0.1:\(port)"))
    }

    static func token(for hostname: String) -> String? {
        Keychain.read(account: hostname, service: Keychain.tunnelService)
    }

    static func setToken(_ token: String, for hostname: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: hostname, service: Keychain.tunnelService) }
        else { _ = Keychain.write(account: hostname, value: trimmed, service: Keychain.tunnelService) }
    }

    /// `token` nil = locally-managed: cloudflared reads its own config.
    func start(hostname: String, token: String?) {
        guard process == nil, let binary = QuickTunnel.binaryPath else { return }
        self.hostname = hostname
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--no-autoupdate", "run"]
        if let token {
            var env = ProcessInfo.processInfo.environment
            env["TUNNEL_TOKEN"] = token
            process.environment = env
        }
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n") {
                let line = String(line)
                if line.contains("Registered tunnel connection") {
                    Task { @MainActor [weak self] in self?.registered() }
                } else if line.contains("Unauthorized") || line.contains("invalid tunnel token")
                            || line.contains("Provided Tunnel token is not valid") {
                    Task { @MainActor [weak self] in
                        self?.status = "Cloudflare rejected the tunnel token"
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.ended() }
        }
        do {
            try process.run()
        } catch {
            status = "couldn't start cloudflared: \(error.localizedDescription)"
            return
        }
        self.process = process
        UserDefaults.standard.set(Int(process.processIdentifier), forKey: Self.pidKey)
        status = "connecting \(hostname)…"
    }

    /// Same orphan story as the quick tunnel: a hard kill leaves the
    /// child running, and the pid has to still look like ours.
    private func reapOrphan() {
        let defaults = UserDefaults.standard
        let pid = defaults.integer(forKey: Self.pidKey)
        defaults.removeObject(forKey: Self.pidKey)
        guard pid > 1, let command = QuickTunnel.commandLine(of: pid),
              command.contains("cloudflared"), command.hasSuffix("run") else { return }
        kill(pid_t(pid), SIGTERM)
    }

    func stop() {
        guard let process else { return }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        self.process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        if process.isRunning { process.terminate() }
        connected = false
        status = nil
    }

    private func registered() {
        guard !connected else { return }
        connected = true
        status = "https://\(hostname)"
        log?("🌐", "named tunnel up at https://\(hostname)")
    }

    private func ended() {
        guard process != nil else { return }
        process = nil
        UserDefaults.standard.removeObject(forKey: Self.pidKey)
        connected = false
        // A rejected token already explains the exit; keep that line.
        if status?.hasPrefix("Cloudflare rejected") != true { status = "the named tunnel stopped" }
        log?("⚠️", "named tunnel stopped")
    }
}
