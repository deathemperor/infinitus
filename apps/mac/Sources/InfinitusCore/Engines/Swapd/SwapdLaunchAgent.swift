import Foundation

#if os(macOS)
/// launchd owns the daemon, its restart policy and its output descriptors.
/// The menu bar is only a client: disconnecting never unloads the agent.
public actor SwapdLaunchAgent: EngineLifecycle {
    public struct Location: Sendable {
        public let home: URL
        public let label: String
        public let uid: UInt32

        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    label: String = "run.infinitus.swapd", uid: UInt32 = getuid()) {
            self.home = home; self.label = label; self.uid = uid
        }

        public var directory: URL {
            home.appendingPathComponent("Library/Application Support/Infinitus/engines")
        }
        public var binary: URL { directory.appendingPathComponent("swapd") }
        public var output: URL { directory.appendingPathComponent("swapd-events.ndjson") }
        public var errors: URL { directory.appendingPathComponent("swapd-errors.log") }
        public var plist: URL {
            home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        }
        public var domain: String { "gui/\(uid)" }
        public var service: String { "\(domain)/\(label)" }
    }

    public typealias Run = @Sendable ([String]) async throws -> Data
    private let source: URL
    private let location: Location
    private let run: Run
    private let onLine: @Sendable (EventLine) -> Void
    private let onState: @Sendable (EngineSupervisor.State) -> Void
    private var operation: Task<Void, Never>?
    private var generation = 0
    private var monitor: Task<Void, Never>?
    private var reader: FileHandle?
    private var buffered = Data()
    private var state: EngineSupervisor.State?

    public init(binaryPath: String, location: Location = Location(),
                run: @escaping Run = { try await SwapdCLI(binaryPath: "/bin/launchctl").run($0) },
                onLine: @escaping @Sendable (EventLine) -> Void,
                onState: @escaping @Sendable (EngineSupervisor.State) -> Void) {
        source = URL(fileURLWithPath: binaryPath)
        self.location = location; self.run = run
        self.onLine = onLine; self.onState = onState
    }

    deinit { monitor?.cancel(); try? reader?.close() }

    /// The binary lives outside the UI bundle, so moving or updating the app
    /// cannot leave launchd pointing at an executable that just disappeared.
    private func install() throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: location.directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: location.plist.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let executable = try Data(contentsOf: source)
        let binaryChanged = (try? Data(contentsOf: location.binary)) != executable
        if binaryChanged {
            try executable.write(to: location.binary, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: location.binary.path)
        }
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": location.label,
            "ProgramArguments": [location.binary.path, "auto", "--json"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            // Not Background: that tier (and every `security` read the engine
            // spawns) gets starved on a busy Mac, reads blow the engine's 15s
            // keychain timeout, and the tick that should switch is fenced.
            "ProcessType": "Standard",
            // Do not inherit the UI's supervised-stdin contract or profile.
            "EnvironmentVariables": ["HOME": location.home.path, "SWAPD_SUPERVISED": "0"],
            "StandardOutPath": location.output.path,
            "StandardErrorPath": location.errors.path,
            "Umask": 0o077,
        ], format: .xml, options: 0)
        let plistChanged = (try? Data(contentsOf: location.plist)) != data
        if plistChanged { try data.write(to: location.plist, options: .atomic) }
        for url in [location.output, location.errors] where !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        return binaryChanged || plistChanged
    }

    private func serial(_ action: @escaping @Sendable () async -> Void) async {
        let previous = operation
        let next = Task { await previous?.value; await action() }
        operation = next
        await next.value
    }

    public func start() async { await serial { await self.startService() } }
    public func stop() async { await serial { await self.stopService() } }
    public func disconnect() async { await serial { await self.detach() } }

    private func startService() async {
        detach()
        do {
            let changed = try install()
            let loaded = (try? await run(["print", location.service])) != nil
            if changed && loaded { _ = try await run(["bootout", location.service]) }
            reader = try FileHandle(forReadingFrom: location.output)
            _ = try reader?.seekToEnd()
            if changed || !loaded {
                _ = try await run(["enable", location.service])
                _ = try await run(["bootstrap", location.domain, location.plist.path])
            }
            await poll()
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { break }
                    await self?.poll()
                }
            }
        } catch {
            publish(.stopped)
            onLine(.garbage("Could not start the background account engine: \(error.localizedDescription)"))
        }
    }

    /// An explicit stop removes the login job too; a future start reinstalls it.
    private func stopService() async {
        detach()
        do {
            if (try? await run(["print", location.service])) != nil {
                _ = try await run(["bootout", location.service])
            }
            if FileManager.default.fileExists(atPath: location.plist.path) {
                try FileManager.default.removeItem(at: location.plist)
            }
            publish(.stopped)
        } catch {
            onLine(.garbage("Could not stop the background account engine: \(error.localizedDescription)"))
            await poll()
        }
    }

    private func detach() {
        generation += 1
        monitor?.cancel(); monitor = nil
        try? reader?.close(); reader = nil
        buffered.removeAll(keepingCapacity: false)
    }

    private func publish(_ value: EngineSupervisor.State) {
        guard value != state else { return }
        state = value; onState(value)
    }

    func poll() async {
        let currentGeneration = generation
        let result = try? await run(["print", location.service])
        guard currentGeneration == generation else { return }
        if let data = result {
            let text = String(decoding: data, as: UTF8.self)
            let pid = text.split(separator: "\n").compactMap { line -> Int32? in
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "pid" else { return nil }
                return Int32(parts[1].trimmingCharacters(in: .whitespaces))
            }.first
            publish(pid.map { .running(pid: $0) } ?? .backingOff(seconds: 30))
        } else { publish(.stopped) }
        // Incremental and bounded: reopening the menu bar never replays its log.
        guard let chunk = try? reader?.read(upToCount: 65_536), !chunk.isEmpty else { return }
        buffered.append(chunk)
        while let newline = buffered.firstIndex(of: 0x0A) {
            let line = String(decoding: buffered[..<newline], as: UTF8.self)
            buffered.removeSubrange(...newline)
            onLine(EventFeed.decode(line: line))
        }
        if buffered.count > 1_048_576 { buffered.removeAll(keepingCapacity: false) }
    }
}
#endif
