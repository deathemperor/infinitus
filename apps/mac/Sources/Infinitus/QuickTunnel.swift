import Foundation
import AppKit
import InfinitusCore

/// Runs `cloudflared tunnel --url http://127.0.0.1:<port>` (#9, #572): a
/// throwaway public hostname, no Cloudflare account, no backend of ours.
/// The URL changes every start. Fronts the fork server's port; the
/// phone mirror it was written for is gone.
@MainActor
final class QuickTunnel: ObservableObject {
    @Published private(set) var url: String?
    @Published private(set) var status: String?
    /// Set by AppModel so tunnel events land in the popup's event log.
    var log: ((String, String) -> Void)?

    private var process: Process?
    /// The child's pid, remembered across launches: a hard kill of the
    /// app (crash, SIGKILL) can't run any cleanup, and a public tunnel
    /// left running afterwards is exactly what nobody asked for.
    private let pidKey: String
    /// The port the running child fronts.
    private(set) var port: UInt16?

    var isRunning: Bool { process != nil }

    init(pidKey: String) {
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
        // --config /dev/null: cloudflared otherwise reads
        // ~/.cloudflared/config.yml, and once the named mirror tunnel
        // (NamedTunnel) has written an ingress there, the quick tunnel's
        // *.trycloudflare.com hostname matches no rule — cloudflared
        // answers its catch-all 404 itself and never contacts the origin
        // (Infi3, fork pairing 2026-09-11). A quick tunnel is one --url
        // and nothing else.
        process.arguments = ["tunnel", "--no-autoupdate", "--config", "/dev/null",
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
                guard let found = CloudflaredOutput.quickTunnelURL(in: String(line)) else {
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
        AppDefaults.standard.set(Int(process.processIdentifier), forKey: pidKey)
        status = "starting a quick tunnel…"
    }

    /// Kills a tunnel a previous launch left behind. Pids are reused, so
    /// the command line has to still look like ours before anything dies.
    private func reapOrphan() {
        let defaults = AppDefaults.standard
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
        AppDefaults.standard.removeObject(forKey: pidKey)
        if process.isRunning { process.terminate() }
        url = nil
        status = nil
    }

    private func adopt(_ found: String) {
        guard url != found else { return }
        url = found
        status = found
        log?("🌐", "quick tunnel up at \(found)")
    }

    private func ended() {
        guard process != nil else { return }
        process = nil
        port = nil
        AppDefaults.standard.removeObject(forKey: pidKey)
        url = nil
        status = "the quick tunnel stopped"
        log?("⚠️", "quick tunnel stopped")
    }
}
