import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import InfinitusCore

// MARK: - Backend-free remote access, mac side (#9)
//
// The rules are all in InfinitusCore.MirrorPairing (token, pair URL,
// which address is a tailnet one). What lives here is the machinery
// AppKit brings: walking the interfaces, drawing a QR, and running a
// cloudflared child for the quick-tunnel mode.

enum LocalAddresses {
    /// Every up, non-loopback IPv4 address on this Mac, in interface
    /// order — so the Wi-Fi/Ethernet address comes before Tailscale's
    /// utun and `MirrorPairing.lanAddress` picks the right one.
    static func ipv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0,
                  let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if !found.contains(text) { found.append(text) }
        }
        return found
    }
}

enum PairQR {
    /// A crisp QR for a pair URL. CoreImage renders one module per pixel,
    /// so it's scaled with nearest-neighbour before it becomes an image.
    static func image(for text: String, side: CGFloat = 132) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // "M": a pair URL is short, and the extra correction survives a
        // phone camera at an angle.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// One way in: a reachable address for the mirror listener plus the QR
/// that pairs a phone with it.
struct PairRoute: Identifiable {
    let id: String
    /// "On this Wi-Fi", "Anywhere via Tailscale", "Anywhere (Cloudflare)".
    let title: String
    let detail: String
    /// `http://192.168.1.20:47824` — what the phone's address field takes.
    let endpoint: String
}

/// Where the tailnet route comes from: a Tailscale client on this Mac.
/// Infinitus never installs it — Tailscale needs an account, a browser
/// sign-in and a VPN-configuration grant, none of which an app can do on
/// the user's behalf — it points the way and notices when it's there.
enum TailscaleStatus: Equatable {
    case notInstalled
    /// App present, no tailnet address: not running, or signed out.
    case installed(URL)
    case connected(String)

    static let downloadURL = URL(string: "https://tailscale.com/download/mac")!

    /// The Mac App Store and the standalone builds carry different ids;
    /// the Homebrew formula is CLI-only and lives in the prefix.
    static var appURL: URL? {
        for id in ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func probe(addresses: [String]) -> TailscaleStatus {
        if let ip = MirrorPairing.tailnetAddress(in: addresses) { return .connected(ip) }
        if let app = appURL { return .installed(app) }
        return .notInstalled
    }
}

/// Runs `cloudflared tunnel --url http://127.0.0.1:<port>` (#9): a
/// throwaway public hostname, no Cloudflare account, no backend of ours.
/// The URL changes every start and the pairing token is the only lock,
/// which is exactly what the Sync pane's help text says.
@MainActor
final class QuickTunnel: ObservableObject {
    @Published private(set) var url: String?
    @Published private(set) var status: String?
    /// Set by AppModel so tunnel events land in the popup's event log.
    var log: ((String, String) -> Void)?
    /// Fires with each URL the tunnel comes up on — the rendezvous publish.
    var onURL: ((String) -> Void)?

    private var process: Process?
    /// The child's pid, remembered across launches: a hard kill of the
    /// app (crash, SIGKILL) can't run any cleanup, and a public tunnel
    /// left running afterwards is exactly what nobody asked for. One
    /// key per instance — the mirror's tunnel and the fork server's
    /// (#572) each remember their own child.
    private let pidKey: String
    /// The port the running child fronts.
    private(set) var port: UInt16?

    var isRunning: Bool { process != nil }

    init(pidKey: String = "mirror_tunnel_pid") {
        self.pidKey = pidKey
        reapOrphan()
        // A child process must not outlive the app that opened a public
        // door with it — the menu's Quit calls stop() through
        // AppModel.shutdown(), and this covers every other orderly exit
        // (Cmd-Q, logout, terminate(nil)).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
    }

    /// cloudflared, if it's installed: Homebrew's two prefixes first,
    /// then whatever PATH says — no subprocess just to find a file.
    static var binaryPath: String? {
        var candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/cloudflared" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isAvailable: Bool { Self.binaryPath != nil }

    func start(port: UInt16) {
        guard process == nil, let binary = Self.binaryPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--no-autoupdate",
                             "--url", "http://127.0.0.1:\(port)"]
        let pipe = Pipe()
        // cloudflared logs the hostname to stderr, in a box of asterisks.
        process.standardError = pipe
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(decoding: chunk, as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let found = MirrorPairing.quickTunnelURL(in: String(line)) else {
                    continue
                }
                Task { @MainActor [weak self] in self?.adopt(found) }
                return
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
        self.port = port
        UserDefaults.standard.set(Int(process.processIdentifier), forKey: pidKey)
        status = "starting a quick tunnel…"
    }

    /// Kills a tunnel a previous launch left behind. Pids are reused, so
    /// the command line has to still look like ours before anything dies.
    private func reapOrphan() {
        let defaults = UserDefaults.standard
        let pid = defaults.integer(forKey: pidKey)
        defaults.removeObject(forKey: pidKey)
        guard pid > 1, let command = Self.commandLine(of: pid),
              command.contains("cloudflared"), command.contains("--url") else { return }
        kill(pid_t(pid), SIGTERM)
    }

    static func commandLine(of pid: Int) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func stop() {
        guard let process else { return }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        self.process = nil
        port = nil
        UserDefaults.standard.removeObject(forKey: pidKey)
        if process.isRunning { process.terminate() }
        url = nil
        status = nil
    }

    private func adopt(_ found: String) {
        guard url != found else { return }
        url = found
        status = found
        log?("🌐", "quick tunnel up at \(found)")
        onURL?(found)
    }

    private func ended() {
        guard process != nil else { return }
        process = nil
        port = nil
        UserDefaults.standard.removeObject(forKey: pidKey)
        url = nil
        status = "the quick tunnel stopped"
        log?("⚠️", "quick tunnel stopped")
    }
}
