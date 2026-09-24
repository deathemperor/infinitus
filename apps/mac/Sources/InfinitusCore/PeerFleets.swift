import Foundation

/// Another machine's fleets in this Mac's popup. The desktop app holds
/// every paired environment and reads each one's live snapshot, so it is
/// the one place that knows what the other machines' engines hold; it
/// pushes that here over the `peer-sync` verb, and takes back the row
/// actions the popup queued for those machines to run on their own
/// servers. The Mac never pairs with another machine itself: the desktop
/// is the only channel, as it is for the phone.
public enum PeerFleets {
    public static let command = "peer-sync"

    /// What the desktop pushes: every other environment that runs
    /// Infinitus, and the outcome of each command it ran since the last
    /// push. `fleets` is nil for a machine whose snapshot has not arrived.
    public struct Body: Codable, Sendable {
        public struct Machine: Codable, Sendable {
            public let id: String
            public let label: String
            public let connected: Bool
            public let fleets: [FleetDoc]?

            public init(id: String, label: String, connected: Bool, fleets: [FleetDoc]?) {
                self.id = id
                self.label = label
                self.connected = connected
                self.fleets = fleets
            }
        }

        public struct Result: Codable, Sendable, Equatable {
            public let id: String
            public let ok: Bool
            public let error: String?

            public init(id: String, ok: Bool, error: String? = nil) {
                self.id = id
                self.ok = ok
                self.error = error
            }
        }

        public let machines: [Machine]
        public let results: [Result]

        public init(machines: [Machine], results: [Result] = []) {
            self.machines = machines
            self.results = results
        }
    }

    /// One fleet as the desktop's contract carries it: this Mac's own
    /// `fleets` reply, minus every key the contract does not name. Its own
    /// document rather than `EngineFleet`, so a key the contract drops or
    /// an engine this build does not know never fails the whole push.
    public struct FleetDoc: Codable, Sendable {
        public let key: String
        public let engineID: String
        public let provider: String
        public let capabilities: [String]
        public let caveat: String?
        public let activeNumber: Int?
        public let nextCandidate: Int?
        public let candidateOrder: [Int]?
        public let nextRecovery: NextRecovery?
        public let accounts: [AccountDoc]

        public init(key: String, engineID: String, provider: String, capabilities: [String],
                    caveat: String? = nil, activeNumber: Int? = nil, nextCandidate: Int? = nil,
                    candidateOrder: [Int]? = nil, nextRecovery: NextRecovery? = nil,
                    accounts: [AccountDoc]) {
            self.key = key
            self.engineID = engineID
            self.provider = provider
            self.capabilities = capabilities
            self.caveat = caveat
            self.activeNumber = activeNumber
            self.nextCandidate = nextCandidate
            self.candidateOrder = candidateOrder
            self.nextRecovery = nextRecovery
            self.accounts = accounts
        }
    }

    public struct AccountDoc: Codable, Sendable {
        public let number: Int
        public let alias: String?
        public let email: String
        public let plan: String?
        public let active: Bool
        public let disabled: Bool?
        public let preferred: Bool?
        public let autoIgnite: Bool?
        public let isOrganization: Bool?
        public let organizationName: String?
        public let organizationUuid: String?
        public let usage: Usage?
        public let usageStatus: String?
        public let usageAgeSeconds: Double?
        public let usageFetchedAt: String?
        /// The banked limit resets as that machine's engine read them (#1554).
        public let resets: AccountResets?

        public init(number: Int, alias: String? = nil, email: String, plan: String? = nil,
                    active: Bool, disabled: Bool? = nil, preferred: Bool? = nil,
                    autoIgnite: Bool? = nil, isOrganization: Bool? = nil,
                    organizationName: String? = nil, organizationUuid: String? = nil,
                    usage: Usage? = nil, usageStatus: String? = nil,
                    usageAgeSeconds: Double? = nil, usageFetchedAt: String? = nil,
                    resets: AccountResets? = nil) {
            self.number = number
            self.alias = alias
            self.email = email
            self.plan = plan
            self.active = active
            self.disabled = disabled
            self.preferred = preferred
            self.autoIgnite = autoIgnite
            self.isOrganization = isOrganization
            self.organizationName = organizationName
            self.organizationUuid = organizationUuid
            self.usage = usage
            self.usageStatus = usageStatus
            self.usageAgeSeconds = usageAgeSeconds
            self.usageFetchedAt = usageFetchedAt
            self.resets = resets
        }

        public var account: Account {
            Account(number: number, email: email,
                    organizationName: organizationName ?? "",
                    organizationUuid: organizationUuid ?? "",
                    isOrganization: isOrganization ?? false,
                    active: active, usageStatus: usageStatus ?? "ok",
                    usage: usage, alias: alias, plan: plan, disabled: disabled,
                    preferred: preferred, autoIgnite: autoIgnite,
                    usageFetchedAt: usageFetchedAt, usageAgeSeconds: usageAgeSeconds,
                    resets: resets)
        }
    }

    /// One row action the popup queued for another machine, in the words
    /// that machine's own control socket takes (`switch <fleet> <n>`), so
    /// the desktop forwards it verbatim and builds nothing itself.
    public struct Command: Codable, Sendable, Equatable {
        public let id: String
        public let machine: String
        public let command: String
        public let args: [String]
        public let options: [String: String]

        public init(id: String = UUID().uuidString, machine: String, command: String,
                    args: [String], options: [String: String] = [:]) {
            self.id = id
            self.machine = machine
            self.command = command
            self.args = args
            self.options = options
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        public let commands: [Command]
        public init(commands: [Command]) { self.commands = commands }
    }

    /// The other machine refused or failed a command, in its own words.
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: engine ids

    /// A peer engine's id: `peer:<environment>:<engine>`, so one machine's
    /// swapd and its proxy stay two engines here as they are there, and
    /// nothing that keys on an engine id ever mistakes a peer for a local
    /// engine.
    public static let engineIDPrefix = "peer:"

    public static func engineID(machine: String, remoteEngine: String) -> String {
        engineIDPrefix + machine + ":" + remoteEngine
    }

    public static func isPeer(engineID: String) -> Bool {
        engineID.hasPrefix(engineIDPrefix)
    }

    // MARK: conversion

    /// The provider a doc names, or `.other` for one this build has no
    /// case for: the row still draws, under the "Other" header.
    public static func provider(_ raw: String) -> Provider {
        Provider(rawValue: raw) ?? .other
    }

    /// The row actions a peer fleet offers: the inverse of the names the
    /// `fleets` reply prints, kept to what a row can send back as one
    /// control command. Adding an account and igniting stay unmapped —
    /// both need the other machine's own screen or a verb this path does
    /// not carry — so those affordances never appear on a peer row.
    public static func capabilities(named names: [String]) -> EngineCapabilities {
        let table: [String: EngineCapabilities] = [
            "switch": .switch, "rotate": .rotate, "hold": .hold, "rename": .rename,
            "remove": .remove, "prefer": .prefer, "autoIgnite": .autoIgnite, "reset": .reset,
        ]
        var caps: EngineCapabilities = []
        for name in names { if let cap = table[name] { caps.insert(cap) } }
        return caps
    }

    /// Each pushed fleet's key on its own machine, by provider — what a
    /// command for that machine names. A provider this build maps to
    /// `.other` keeps the key its machine printed, so the command still
    /// lands.
    public static func remoteKeys(_ docs: [FleetDoc]) -> [Provider: String] {
        Dictionary(docs.map { (provider($0.provider), $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    /// The doc as the fleet the popup stacks, under the peer engine's id.
    public static func engineFleet(_ doc: FleetDoc, engineID: String) -> EngineFleet {
        EngineFleet(engineID: engineID, provider: provider(doc.provider),
                    accounts: doc.accounts.map(\.account),
                    activeNumber: doc.activeNumber, nextCandidate: doc.nextCandidate,
                    candidateOrder: doc.candidateOrder, nextRecovery: doc.nextRecovery,
                    capabilities: capabilities(named: doc.capabilities))
    }
}

/// The commands the popup's peer rows are waiting on. A row's action
/// enqueues one and awaits its outcome; the desktop drains the queue on
/// its next `peer-sync`, runs each command on that machine's server and
/// reports back on the push after. A command nobody answers within
/// `timeout` fails as unreachable, so a closed desktop never leaves a row
/// spinning; a result for a command already timed out is dropped.
public actor PeerCommandQueue {
    private var waiting: [PeerFleets.Command] = []
    private var continuations: [String: CheckedContinuation<Void, Error>] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) { self.timeout = timeout }

    /// Commands queued or handed out and not yet answered.
    public var pendingCount: Int { continuations.count }

    /// Queue `command` and wait for the machine's answer.
    public func run(_ command: PeerFleets.Command) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting.append(command)
            continuations[command.id] = continuation
            let seconds = timeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await self?.expire(command.id)
            }
        }
    }

    /// The commands queued since the last drain, for the desktop to run.
    /// They stay pending here until a result or the timeout ends them.
    public func drain() -> [PeerFleets.Command] {
        defer { waiting = [] }
        return waiting
    }

    public func resolve(_ result: PeerFleets.Body.Result) {
        guard let continuation = continuations.removeValue(forKey: result.id) else { return }
        waiting.removeAll { $0.id == result.id }
        if result.ok {
            continuation.resume()
        } else {
            continuation.resume(throwing: PeerFleets.Failure(result.error ?? "the command failed on the other machine"))
        }
    }

    private func expire(_ id: String) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        waiting.removeAll { $0.id == id }
        continuation.resume(throwing: PeerFleets.Failure(
            "The desktop app did not answer within \(Int(timeout)) s. Check it is open, then try again."))
    }
}
