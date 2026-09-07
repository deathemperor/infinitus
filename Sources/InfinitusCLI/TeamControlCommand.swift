import Foundation
import InfinitusCore

// `infinitusctl team grant | revoke | grants` (#220 §7.3): who may drive
// which of this machine's sessions. Writes <teamDir>/grants.json, which
// the Mac's grantor endpoint reads per request — no socket needed.

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(value) else { exit(controlFail("could not encode the result")) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func controlFail(_ message: String, code: Int32 = 1) -> Int32 {
    let text = message.hasPrefix("usage:") ? message : "error: \(TeamGit.masked(message))"
    FileHandle.standardError.write(Data((text + "\n").utf8))
    return code
}

/// nil when `args` is not one of ours.
func runTeamControl(_ args: [String]) -> Int32? {
    guard let sub = args.first, ["grant", "revoke", "grants"].contains(sub) else { return nil }
    let capabilityFlags: Set<String> = [TeamGrants.view, TeamGrants.send, TeamGrants.approve, TeamGrants.mode, TeamGrants.resume, TeamGrants.key]
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if capabilityFlags.contains(key) || key == "json" { flags.insert(key); i += 1; continue }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return controlFail("--\(key) needs a value\n\n\(teamUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
    // Delegating control is at least as sensitive as admitting a member:
    // the same team gate as `approve` (TeamGate.swift).
    if ["grant", "revoke"].contains(sub),
       case .needsLock(let why) = TeamGate.check(lockEnabled: LockSetting.enabledOnThisMachine()) {
        return controlFail("\(why) (Infinitus › Settings › Lock)")
    }
    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)
    do {
        let ids = paths.teamIDs()
        guard let id = options["team"] ?? (ids.count == 1 ? ids[0] : nil) else {
            return controlFail(ids.isEmpty ? "no team on this machine (create or request one)"
                                           : "several teams: pass --team <id> (\(ids.joined(separator: ", ")))")
        }
        guard TeamClient.isPathSegment(id) else { return controlFail("--team takes a team id (one path segment)", code: 2) }
        let client = try TeamClient.open(id: id, paths: paths, secrets: secrets)
        let teamDir = paths.teamDir(id)
        var grants = TeamGrants.load(teamDir: teamDir)
        switch sub {
        case "grant":
            guard let audience = TeamShares.parseTarget(Array(positional.prefix(1))), audience != .off else {
                return controlFail(teamUsage(), code: 2)
            }
            let capabilities = flags.intersection(capabilityFlags)
            guard !capabilities.isEmpty else { return controlFail("pick at least one of --view --send --approve --mode --resume --key", code: 2) }
            if case .members(let kids) = audience {
                let known = Set(client.roster?.doc.everyone.map(\.keys.kid) ?? [])
                for kid in kids where !known.contains(kid) { return controlFail("unknown kid \(kid)", code: 2) }
            }
            let sessions: TeamGrants.Sessions = options["sessions"]
                .map { .some($0.split(separator: ",").map(String.init).filter { !$0.isEmpty }) } ?? .all
            let grant = grants.add(audience: audience, sessions: sessions, capabilities: capabilities,
                                   now: Int(Date().timeIntervalSince1970))
            try grants.save(teamDir: teamDir)
            emit(grant)
        case "revoke":
            guard let id = positional.first else { return controlFail(teamUsage(), code: 2) }
            let removed = grants.remove(id: id)
            if removed { try grants.save(teamDir: teamDir) }
            emit(["removed": removed])
        default:
            emit(grants)
        }
        return 0
    } catch {
        return controlFail(error.localizedDescription)
    }
}
