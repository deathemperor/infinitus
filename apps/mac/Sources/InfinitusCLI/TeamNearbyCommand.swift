import Foundation
import InfinitusCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

// `infinitusctl team nearby | request --nearby <kid> | --discoverable`
// (spec §6.4, §9 "Linux/Windows discovery"): the mDNS browser and
// responder from MDNS.swift, the two LAN routes over PosixHTTPServer.
// Its own file so TeamCommand.swift (the publisher's) carries only the
// dispatch line at the top of `runTeam`.

func teamNearbyUsage() -> String {
    """
    usage: infinitusctl team nearby [--seconds N]
               list Infinitus machines on this network (default 3 s)
           infinitusctl team nearby invite <kid|name> [--days N] [--seconds N] [--as <n>] [--team <id>]
               (leader) seal an invite link to that discoverable machine and send it over the LAN
           infinitusctl team invites
               invitations sent to this machine (never the link inside)
           infinitusctl team accept <kid> --name <n> [--devices a,b]
               open the invitation from that kid and ask to join its team
           infinitusctl team ignore <kid>
               delete that invitation
           infinitusctl team request --nearby <kid> --name <n> [--devices a,b] [--seconds N]
               send a join request to that leader over the LAN — no code to paste
           infinitusctl team request --address <host[:port]> --name <n> [--devices a,b]
               the same, to a leader you can reach by address when the network hides Bonjour
           infinitusctl team --discoverable [--name <n>] [--port N]
               advertise this machine and answer /team/key + /team/request + /team/invite until Ctrl-C (Linux;
               on the Mac the app advertises: `infinitusctl team-discoverable on`).
               Binds every interface: run it on a LAN you trust, never on a box with a public address.

    """
}

#if os(macOS)
private let nearbyPlatform = "macos"
#elseif os(Linux)
private let nearbyPlatform = "linux"
#else
private let nearbyPlatform = "windows"
#endif

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        print(String(decoding: try enc.encode(value), as: UTF8.self))
    } catch {
        exit(fail("could not encode the result: \(error)"))   // not silence and 0 (#55)
    }
}

private func fail(_ message: String, code: Int32 = 1) -> Int32 {
    let prefix = message.hasPrefix("usage:") ? "" : "error: "
    FileHandle.standardError.write(Data("\(prefix)\(TeamGit.masked(message))\n".utf8))
    return code
}

/// What `team invites` prints. The sealed envelope — and so the link and
/// its store credential — is never in it.
private struct InviteRow: Encodable {
    var from: String, kid: String, team: String, at: Int
}

private struct InviteSent: Encodable {
    var ok: Bool, team: String, teamName: String, to: String
}

private struct AcceptedInvite: Encodable {
    var team: String, name: String, kid: String
}

/// nil when `args` is not a nearby command — `runTeam` carries on.
func runTeamNearby(_ args: [String]) -> Int32? {
    guard let sub = args.first else { return nil }
    let mine = sub == "nearby" || sub == "--discoverable" || sub == "invites" || sub == "accept" || sub == "ignore"
        || (sub == "request" && args.contains("--nearby"))
    guard mine else { return nil }
    if args.contains("--help") || args.contains("-h") {
        print(teamNearbyUsage(), terminator: "")
        return 0
    }
    // Every option takes a value; a bare flag is a typo (same rule as
    // `runTeam`). Positionals name a subcommand's target — `nearby
    // invite <kid>`, `accept <kid>`.
    var options: [String: String] = [:]
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return fail("--\(key) needs a value\n\n\(teamNearbyUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }
    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)
    let seconds = Double(options["seconds"] ?? "3") ?? 3
    do {
        switch sub {
        case "nearby":
            if positional.first == "invite" {
                guard let target = positional.dropFirst().first, positional.count == 2 else {
                    return fail(teamNearbyUsage(), code: 2)
                }
                // Parsed and validated before the 2-3s mDNS browse below,
                // so a typo'd `--days` fails fast rather than after the wait.
                guard let days = Int(options["days"] ?? "7"), days >= 1 else {
                    return fail(teamNearbyUsage(), code: 2)
                }
                guard let peer = try TeamNearby.Client.browse(seconds: seconds).first(where: {
                    $0.discoverable && ($0.kid == target || $0.name == target)
                }) else {
                    return fail("no discoverable machine called \(target) answered within \(Int(seconds))s")
                }
                let machine = options["as"] ?? ProcessInfo.processInfo.hostName
                do {
                    let out = try TeamNearby.Client.invite(to: peer, fromName: machine, days: days,
                                                           team: options["team"], paths: paths, secrets: secrets,
                                                           http: { m, h, p, path, body in try http(m, host: h, port: p, path: path, body: body) })
                    emit(InviteSent(ok: out.ok, team: out.team, teamName: out.teamName, to: out.to))
                } catch TeamNearby.Client.ClientError.notALeader {
                    // `.notALeader` also covers the peer-side guard in
                    // `Client.invite` (not discoverable, or no kid) — but
                    // `browse` only ever hands back peers with both, so
                    // this machine leading no team is the reachable cause.
                    if !peer.discoverable || peer.kid == nil {
                        return fail("\(peer.name) is no longer discoverable enough to invite")
                    }
                    return fail("this machine leads no team (\(peer.name) can only be invited by a leader)")
                } catch TeamNearby.Client.ClientError.keyMismatch(let s) {
                    return fail("\(peer.name) is not answering \(TeamNearby.keyPath) (\(s))")
                } catch TeamNearby.Client.ClientError.refused(let s) {
                    return fail("\(peer.name) refused the invitation (\(s))")
                }
                break
            }
            guard positional.isEmpty else { return fail(teamNearbyUsage(), code: 2) }
            emit(try TeamNearby.Client.browse(seconds: seconds))
        case "invites":
            guard positional.isEmpty else { return fail(teamNearbyUsage(), code: 2) }
            emit(TeamNearby.Store.invites(paths: paths).map {
                InviteRow(from: $0.fromName, kid: $0.from.kid, team: $0.teamName, at: $0.at)
            })
        case "accept":
            guard let kid = positional.first, positional.count == 1, let name = options["name"] else {
                return fail(teamNearbyUsage(), code: 2)
            }
            guard let invite = TeamNearby.Store.invites(paths: paths).first(where: { $0.from.kid == kid }) else {
                return fail("no invitation from \(kid) (`infinitusctl team invites` lists them)")
            }
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            let opened = try TeamNearby.openInvite(invite, identity: me)
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            let joined = try TeamClient.request(code: opened.text, name: name, devices: devices,
                                                platform: nearbyPlatform, paths: paths, secrets: secrets)
            try TeamNearby.Store.removeInvite(from: kid, paths: paths)
            emit(AcceptedInvite(team: joined.config.id, name: joined.config.name, kid: me.kid))
        case "ignore":
            guard let kid = positional.first, positional.count == 1 else { return fail(teamNearbyUsage(), code: 2) }
            try TeamNearby.Store.removeInvite(from: kid, paths: paths)
            emit(["ignored": kid])
        case "request":
            guard positional.isEmpty, let name = options["name"], options["nearby"] != nil || options["address"] != nil else {
                return fail(teamNearbyUsage(), code: 2)
            }
            let peer: TeamNearby.Peer
            if let address = options["address"] {
                guard let (host, port) = TeamNearby.Client.parseAddress(address) else { return fail("--address wants host or host:port", code: 2) }
                do { peer = try TeamNearby.Client.peer(host: host, port: port, http: { m, h, p, path, body in try http(m, host: h, port: p, path: path, body: body) }) }
                catch { return fail("nothing at \(host):\(port) answers as an Infinitus leader (\(error))") }
            } else {
                let kid = options["nearby"] ?? ""
                guard let found = try TeamNearby.Client.browse(seconds: seconds).first(where: { $0.kid == kid && $0.discoverable }) else {
                    return fail("no discoverable machine with kid \(kid) answered within \(Int(seconds))s")
                }
                peer = found
            }
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            do {
                let out = try TeamNearby.Client.request(to: peer, name: name, devices: devices, platform: nearbyPlatform,
                                                        paths: paths, secrets: secrets,
                                                        http: { m, h, p, path, body in try http(m, host: h, port: p, path: path, body: body) })
                emit(["team": out.team, "leader": out.leader, "kid": out.kid, "stored": out.stored])
            } catch TeamNearby.Client.ClientError.notALeader {
                return fail("\(peer.name) leads no team")
            } catch TeamNearby.Client.ClientError.keyMismatch(let s) {
                return fail("\(peer.name) is not answering \(TeamNearby.keyPath) (\(s))")
            } catch TeamNearby.Client.ClientError.refused(let s) {
                return fail("\(peer.name) refused the request (\(s))")
            }
        case "--discoverable":
            guard positional.isEmpty else { return fail(teamNearbyUsage(), code: 2) }
            return runDiscoverable(name: options["name"], port: UInt16(options["port"] ?? "0") ?? 0,
                                   paths: paths, secrets: secrets)
        default:
            return nil
        }
        return 0
    } catch {
        return fail("\(error)")
    }
}

/// One blocking HTTP exchange with a peer; the CLI has no event loop to
/// hand a completion to.
private func http(_ method: String, host: String, port: UInt16, path: String, body: Data? = nil) throws -> (Int, Data) {
    let bracketed = host.contains(":") ? "[\(host)]" : host
    guard let url = URL(string: "http://\(bracketed):\(port)\(path)") else {
        throw NSError(domain: "team", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad peer address \(host):\(port)"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 10
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let done = DispatchSemaphore(value: 0)
    var result: (Int, Data) = (0, Data())
    var failure: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { failure = error }
        else { result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    if let failure { throw failure }
    return result
}

/// Set from the signal handler; read by the main thread's wait loop.
private var discoverableStopRequested = false

private func runDiscoverable(name: String?, port: UInt16, paths: TeamPaths, secrets: TeamSecrets) -> Int32 {
    #if canImport(Glibc)
    let machine = name ?? ProcessInfo.processInfo.hostName
    let local = TeamNearby.Local.load(name: machine, discoverable: true, paths: paths, secrets: secrets)
    let endpoint = TeamNearby.Endpoint(local: local,
                                       store: { try TeamNearby.Store.save($0, paths: paths, secrets: secrets) },
                                       storeInvite: { try TeamNearby.Store.saveInvite($0, paths: paths) })
    let server = PosixHTTPServer { request in
        TeamNearby.respond(request, endpoint: endpoint) ?? MirrorTransport.notFoundResponse()
    }
    do {
        let bound = try server.start(port: port)
        let ipv4 = PosixInterfaceAddresses.ipv4().first ?? "127.0.0.1"
        let service = MDNS.Service(instance: machine, host: MDNS.hostLabel(machine), port: bound,
                                   txt: local.record.txtStrings, ipv4: ipv4)
        let advertiser = try MDNS.Advertiser(service: service)
        try advertiser.start()
        FileHandle.standardError.write(Data(
            "discoverable as \(machine) (kid \(local.record.kid), \(local.record.role)) on \(ipv4):\(bound) — Ctrl-C to stop\n".utf8))
        // Ctrl-C sends the goodbye first: a bare SIGINT death would leave
        // a stale PTR in every browser's cache for 75 minutes. A
        // non-capturing C handler flips a flag (SIG_IGN is a macro cast
        // Glibc doesn't import; libdispatch signal sources are Darwin-shaped).
        signal(SIGINT) { _ in discoverableStopRequested = true }
        signal(SIGTERM) { _ in discoverableStopRequested = true }
        while !discoverableStopRequested { Thread.sleep(forTimeInterval: 0.25) }
        advertiser.stop()
        server.stop()
        return 0
    } catch {
        return fail("\(error)")
    }
    #else
    return fail("`team --discoverable` serves on Linux; on the Mac the Infinitus app advertises — `infinitusctl team-discoverable on`",
                code: 2)
    #endif
}
