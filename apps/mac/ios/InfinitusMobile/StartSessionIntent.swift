import AppIntents
import InfinitusCore

/// Siri / Spotlight / Shortcuts: "Start a session in Infinitus" (#91,
/// the "run a speed test" card the user pointed at). The repository is
/// matched by folder name against what the Mac has run lately, else
/// taken as a path. The Mac is one of the paired ones (#144) — an
/// entity, so "on <Mac>" works spoken; left blank it is the one the
/// start sheet would pick.
struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a session"
    static let description = IntentDescription("Opens a new Claude Code session in a repository on your Mac.")

    /// A saved profile's name (#165) — its folder stands in for a
    /// repository left blank; its engine, permissions, model, system
    /// prompt and first prompt ride along the way the sheet's chips do.
    @Parameter(title: "Profile")
    var profile: String?

    @Parameter(title: "Repository")
    var repo: String?

    @Parameter(title: "First prompt")
    var prompt: String?

    @Parameter(title: "Mac")
    var mac: MacEntity?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (macId, machine, mirror, recent, profiles) = try await MainActor.run {
            let model = MirrorModel.shared
            let macId = mac.map(\.macId) ?? model.defaultTargetMacId
            // A saved shortcut can outlive its pairing; `mirror(for:)`
            // would quietly fall back to the primary.
            if let macId, model.other(macId) == nil {
                throw StartSessionError(message: "\(mac?.name ?? "That Mac") isn't paired any more.")
            }
            if let macId, model.other(macId)?.parked == true {
                throw StartSessionError(message: "\(model.machineName(macId: macId)) isn't reachable right now.")
            }
            return (macId, model.machineName(macId: macId), model.mirror(for: macId),
                    model.recentCwds(macId: macId), model.profiles(macId: macId))
        }
        var chosen: SessionProfile?
        if let profile, !profile.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let hit = profiles.first(where: { SessionProfiles.same($0.name, profile.trimmingCharacters(in: .whitespaces)) }) else {
                throw StartSessionError(message: "No profile named \(profile) on \(machine).")
            }
            chosen = hit
        }
        let typed = repo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cwd: String
        if !typed.isEmpty {
            cwd = recent.first { ($0 as NSString).lastPathComponent.lowercased() == typed.lowercased() } ?? typed
        } else if let folder = chosen?.cwd, !folder.isEmpty {
            cwd = folder
        } else {
            throw StartSessionError(message: "Which repository? Name one, or a profile that has a folder.")
        }
        let engine = chosen?.engine ?? "claude"
        let claude = engine == "claude"
        let reply = try await mirror.startSession(
            SessionStart.Request(cwd: cwd, engine: engine,
                                 prompt: prompt ?? chosen?.prompt,
                                 permissionMode: claude ? chosen?.permissionMode : nil,
                                 model: claude ? chosen?.model : nil,
                                 systemPrompt: claude ? chosen?.systemPrompt : nil,
                                 profile: chosen?.name))
        guard reply.outcome == "started" else { throw StartSessionError(message: reply.detail ?? reply.outcome) }
        if let pid = reply.pid {
            await MainActor.run {
                // The Mac that started it, so the Sessions tab opens its feed.
                MirrorModel.shared.requestedMacId = macId
                MirrorModel.shared.requestedPid = pid
                MirrorModel.shared.requestedTab = "sessions"
            }
        }
        let name = (cwd as NSString).lastPathComponent
        let born = chosen.map { " as \($0.name)" } ?? ""
        let on = macId == nil ? "" : " on \(machine)"
        return .result(dialog: "Started in \(name)\(born)\(on)\(reply.host.map { " via \($0)" } ?? "").")
    }
}

/// One paired Mac for the Siri parameter: the primary under a fixed id
/// (it has no pairing record of its own), each other Mac under its
/// pairing id. Names come from what the Mac last called itself.
struct MacEntity: AppEntity {
    static let primaryID = "primary"
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mac"
    static let defaultQuery = MacQuery()

    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    var macId: String? { id == Self.primaryID ? nil : id }

    /// Primary first, the way the start sheet lists them.
    @MainActor static func all() -> [MacEntity] {
        let model = MirrorModel.shared
        return [MacEntity(id: primaryID, name: model.machineName(macId: nil))]
            + model.others.map { MacEntity(id: $0.id, name: $0.pairing.name) }
    }
}

struct MacQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MacEntity] {
        await MacEntity.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MacEntity] {
        await MacEntity.all()
    }
}

struct StartSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct InfinitusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSessionIntent(),
                    phrases: ["Start a session in \(.applicationName)", "Start an \(.applicationName) session",
                              "Start a session on \(\.$mac) in \(.applicationName)",
                              "Start an \(.applicationName) session on \(\.$mac)"],
                    shortTitle: "Start a session", systemImageName: "terminal")
    }
}
