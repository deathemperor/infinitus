import Foundation
import InfinitusCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// `infinitusctl team grant | revoke | grants` (#220 §7.3): who may drive
// which of this machine's sessions. Writes <teamDir>/grants.json, which
// the Mac's grantor endpoint reads per request — no socket needed.
// `send | approve | mode | tail | acks`: driving a teammate's session from
// this machine's own identity — LAN, tunnel, then the store (§5.3).

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
    guard let sub = args.first, ["grant", "revoke", "grants", "send", "approve", "mode", "tail", "acks", "hostname", "drive"].contains(sub) else { return nil }
    let capabilityFlags = Set(TeamGrants.capabilities)
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            // Capability names are bare flags only on `grant`; `team send --send` would otherwise be swallowed.
            if (sub == "grant" && capabilityFlags.contains(key)) || key == "json" || key == "follow" { flags.insert(key); i += 1; continue }
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return controlFail("--\(key) needs a value\n\n\(teamUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
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
            guard !capabilities.isEmpty else {
                return controlFail("pick at least one of \(capabilityFlags.sorted().map { "--\($0)" }.joined(separator: " "))", code: 2)
            }
            if case .members(let kids) = audience {
                let known = Set(client.roster?.doc.everyone.map(\.keys.kid) ?? [])
                for kid in kids where !known.contains(kid) { return controlFail("unknown kid \(kid)", code: 2) }
            }
            let sessions: TeamGrants.Sessions = options["sessions"]
                .map { .some($0.split(separator: ",").map(String.init).filter { !$0.isEmpty }) } ?? .all
            let preauthorized: Set<String> = options["pre"]
                .map { Set($0.split(separator: ",").map(String.init).filter { !$0.isEmpty }) } ?? []
            let expires: Int?
            if let text = options["expires"] {
                guard let seconds = Int(text), seconds > 0 else { return controlFail("--expires takes seconds from now", code: 2) }
                expires = Int(Date().timeIntervalSince1970) + seconds
            } else {
                expires = nil
            }
            let grant = grants.add(audience: audience, sessions: sessions, capabilities: capabilities,
                                   preauthorized: preauthorized, expires: expires,
                                   now: Int(Date().timeIntervalSince1970))
            try grants.save(teamDir: teamDir)
            emit(grant)
        case "revoke":
            guard let id = positional.first else { return controlFail(teamUsage(), code: 2) }
            let removed = grants.remove(id: id)
            if removed { try grants.save(teamDir: teamDir) }
            emit(["removed": removed])
        case "send", "approve", "mode":
            guard positional.count >= 2 else { return controlFail(teamUsage(), code: 2) }
            let (kid, session) = (positional[0], positional[1])
            let text: String
            switch sub {
            case "send":
                let stdin = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !stdin.isEmpty else { return controlFail("team send: the message comes on stdin", code: 2) }
                text = stdin
            case "approve":
                guard positional.count == 3, ["allow", "deny"].contains(positional[2]) else { return controlFail(teamUsage(), code: 2) }
                text = positional[2]
            default:
                guard positional.count == 3 else { return controlFail(teamUsage(), code: 2) }
                text = positional[2]
            }
            _ = try client.fetch()
            let endpoints = try TeamReader.load(client: client).members[kid]?.now?.endpoints
            var deliver = TeamControl.Deliver(http: controlHTTP, interfaces: InterfaceAddresses.ipv4())
            let command = TeamControl.Command(id: TeamControl.newCommandID(), to: kid, session: session, action: sub, text: text,
                                              at: Int(Date().timeIntervalSince1970))
            emit(try TeamControl.Drive.send(command, client: client, endpoints: endpoints, deliver: &deliver))
        case "drive":
            // #220 Phase 2: any granted capability, not just the drive
            // set — the grantor's own verbs (stop, resume-past, delete,
            // swap, hold, kill, reclaim) ride the same envelope.
            guard positional.count >= 3 else { return controlFail(teamUsage(), code: 2) }
            let (kid, session, action) = (positional[0], positional[1], positional[2])
            guard action != TeamGrants.view, TeamGrants.capabilities.contains(action) else { return controlFail(teamUsage(), code: 2) }
            let text = positional.dropFirst(3).joined(separator: " ")
            _ = try client.fetch()
            let endpoints = try TeamReader.load(client: client).members[kid]?.now?.endpoints
            var deliver = TeamControl.Deliver(http: controlHTTP, interfaces: InterfaceAddresses.ipv4())
            let command = TeamControl.Command(id: TeamControl.newCommandID(), to: kid, session: session, action: action,
                                              text: text.isEmpty ? nil : text, at: Int(Date().timeIntervalSince1970))
            emit(try TeamControl.Drive.send(command, client: client, endpoints: endpoints, deliver: &deliver))
        case "tail":
            guard positional.count >= 2 else { return controlFail(teamUsage(), code: 2) }
            let (kid, session) = (positional[0], positional[1])
            _ = try client.fetch()
            let endpoints = try TeamReader.load(client: client).members[kid]?.now?.endpoints
            var deliver = TeamControl.Deliver(http: controlHTTP, interfaces: InterfaceAddresses.ipv4())
            var since: String?
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            repeat {
                guard let (lane, body) = try TeamControl.Drive.tail(kid: kid, session: session, since: since, identity: client.identity,
                                                                    endpoints: endpoints, deliver: &deliver),
                      let feed = try? decoder.decode(SessionFeed.self, from: body) else {
                    return controlFail("no live tail from \(kid) (no reachable endpoint, or no view grant)")
                }
                if since == nil { FileHandle.standardError.write(Data("# \(lane.label) · \(feed.status ?? "?")\n".utf8)) }
                if feed.stamp != since || since == nil {
                    for item in feed.items { print("\(item.kind.rawValue)\t\(item.text.replacingOccurrences(of: "\n", with: "\n\t"))") }
                    since = feed.stamp
                }
                if flags.contains("follow") { Thread.sleep(forTimeInterval: 3) }
            } while flags.contains("follow")
        case "acks":
            _ = try client.fetch()
            let reader = try TeamReader.load(client: client)
            struct Row: Encodable { var id: String; var from: String; var outcome: String; var detail: String?; var at: Int }
            let rows = reader.members.values
                .flatMap { m in m.acks.values.map { Row(id: $0.id, from: m.kid, outcome: $0.outcome, detail: $0.detail, at: $0.at) } }
                .sorted { $0.at > $1.at }
            _ = try TeamControl.Store.driverReap(client: client, acks: reader.ackIDs)
            emit(rows)
        case "hostname":
            // §5.4 / §7.3: the leader's Cloudflare token on stdin once, then a hostname per member.
            func cloudflare() throws -> TeamHostnames.Cloudflare {
                guard let data = secrets.read(TeamHostnames.secretName), let token = String(data: data, encoding: .utf8) else {
                    throw TeamHostnames.HostnameError.notConfigured
                }
                return .init(token: token, http: controlHTTP)
            }
            switch positional.first ?? "" {
            case "token":
                guard positional.count >= 2 else {
                    return controlFail("usage: infinitusctl team hostname token <zone> [--label team]   # Cloudflare API token on stdin", code: 2)
                }
                let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty else { return controlFail("no token on stdin", code: 2) }
                var ledger = try TeamHostnames.ledger(zone: positional[1], label: options["label"] ?? TeamHostnames.defaultLabel, teamDir: teamDir)
                let ids = try TeamHostnames.Cloudflare(token: token, http: controlHTTP).ids(ledger: &ledger)
                try secrets.write(TeamHostnames.secretName, Data(token.utf8))
                try ledger.save(teamDir: teamDir)
                emit(["zone": ledger.zone, "label": ledger.label, "account": ids.account, "zoneID": ids.zone])
            case "give":
                guard positional.count >= 2 else { return controlFail("usage: infinitusctl team hostname give <kid>", code: 2) }
                guard var ledger = TeamHostnames.Ledger.load(teamDir: teamDir) else { throw TeamHostnames.HostnameError.notConfigured }
                _ = try client.fetch()
                let record = try TeamHostnames.give(client: client, kid: positional[1], cloudflare: try cloudflare(), ledger: &ledger)
                try ledger.save(teamDir: teamDir)
                emit(["kid": positional[1], "hostname": record.hostname])
            case "list":
                struct Row: Encodable { var kid: String; var name: String?; var hostname: String; var at: Int; var orphaned: Bool }
                let roster = client.roster?.doc
                let rows = (TeamHostnames.Ledger.load(teamDir: teamDir)?.records ?? [:]).map { kid, r in
                    Row(kid: kid, name: roster?.everyone.first { $0.keys.kid == kid }?.name, hostname: r.hostname, at: r.at,
                        orphaned: roster?.keys(for: kid) == nil)
                }
                emit(rows.sorted { $0.hostname < $1.hostname })
            default:
                return controlFail("usage: infinitusctl team hostname <token <zone> [--label team] | give <kid> | list>", code: 2)
            }
        default:
            emit(grants)
        }
        return 0
    } catch {
        return controlFail(error.localizedDescription)
    }
}

/// One exchange with a grantor's endpoint; the lane's timeout caps it.
let controlHTTP: TeamControl.Deliver.HTTP = { method, url, headers, body, timeout in
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = timeout
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if body != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var result: (Int, Data) = (0, Data()); var failure: Error? }
    let box = Box()
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { box.failure = error } else { box.result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    if let failure = box.failure { throw failure }
    return box.result
}
