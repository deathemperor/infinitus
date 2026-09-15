import Foundation
import InfinitusCore

// `infinitusctl team …` runs in-process — no control socket, so a Linux
// or Windows member needs only this binary (spec §9). State lives under
// TeamPaths.standard() (override: INFINITUS_TEAM_DIR); secrets in
// FileSecrets under it. On a Mac the app keeps this machine's identity
// and store tokens in the keychain, which this process cannot read, so
// with the app running and no INFINITUS_TEAM_DIR the subcommands the
// app answers go through its control socket, and the rest refuse to
// mint a second identity beside the app's (#354: a leader Mac ended up
// with two kids, and a CLI join the app never saw).

func teamUsage() -> String {
    """
    usage: infinitusctl team <subcommand> [args] [--option value]

      create <name> --remote <url> [--token -] [--as <your name>]     create a team on an empty git remote (token from stdin)
      code [--days N]                              team code for joiners (default 7 days)
      request - --name <n> [--devices a,b]         ask to join; the code on stdin (argv only if it carries no credential)
      status [--team <id>]                         this machine's team(s), fetched first (cached, with a warning, when the store is unreachable)
      requests                                     pending join requests (leaders)
      approve <kid> | decline <kid>                answer a request (leaders)
      remove <kid> | promote <kid>                 roster edits (leaders; the founder cannot be removed)
      fetch                                        pull the store and accept the roster
      policy [--requests code|off] [--members-see-each-other on|off]   (leaders) show or set the roster policy
      share <kind> off|leaders|team|<kid>[,<kid>…]  audience for stats|now|sessions|transcripts|crashes|fleet ("off" keeps it on this machine; new envelopes only)
      leave [--rotate-identity]                    delete my files on the store, tell the leaders, forget the team here (and mint a new identity)
      exclude <project-dir> [--off]                keep a Claude Code project private (local, never sent)
      identity [show]                    this machine's identity kid
      identity recovery --show           the recovery key (base32, 8 groups) — keep it offline
      identity export [--out <file>]     passphrase on stdin (≥ 8 chars); the sealed file to --out (0600) or stdout
      identity import <file> | --recovery [--replace]   passphrase or recovery key on stdin
      put --kind <k> --path <p> --file <f> [--audience leaders|team|<kid,kid>]   one opaque file (debugging)
      list                                         envelopes addressed to me
      read <path> [--out <file>]                   decrypt one envelope

    Narrowing an audience cannot recall ciphertext teammates already fetched.

    """
}

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
        print(String(decoding: try enc.encode(value), as: UTF8.self))
    } catch {
        // Silence and exit 0 would read as "nothing to report" (#55).
        exit(fail("could not encode the result: \(error)"))
    }
}

/// Every error path prints through here, so the mask lives here: git's
/// stderr quotes the remote as configured, credential and all (#55).
private func masked(_ message: String) -> String { TeamGit.masked(message) }

private func fail(_ message: String, code: Int32 = 1) -> Int32 {
    let prefix = message.hasPrefix("usage:") ? "" : "error: "   // not "error: usage:"
    FileHandle.standardError.write(Data("\(prefix)\(masked(message))\n".utf8))
    return code
}

#if os(macOS)
/// The subcommands the running app answers itself (ControlServer's
/// `team-*` verbs), as the app's view — the app's identity, the app's
/// store. nil when the app is not running (the caller stays in-process)
/// or the subcommand has no app verb.
private func routeToApp(_ sub: String, positional: [String], options: [String: String], socket: String) -> Int32? {
    let request: ControlRequest
    switch sub {
    case "status": request = ControlRequest(command: "team-status")
    case "fetch": request = ControlRequest(command: "team-fetch")
    case "code": request = ControlRequest(command: "team-code", options: options.filter { $0.key == "days" })
    case "approve", "decline":
        guard let kid = positional.first else { return nil }
        request = ControlRequest(command: "team-\(sub)", args: [kid])
    case "create":
        guard let name = positional.first, let remote = options["remote"] else { return nil }
        request = ControlRequest(command: "team-create", args: [name, remote],
                                 options: ["remote": remote].merging(options.filter { $0.key == "as" }) { a, _ in a })
    default: return nil
    }
    guard let reply = ControlClient.roundTripRetrying(request, path: socket) else { return nil }
    guard reply.ok else { return fail(reply.error ?? "\(request.command) failed") }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(reply.result ?? .null) { print(String(decoding: data, as: UTF8.self)) }
    return 0
}
#endif

private struct ReadableEntry: Encodable {
    var path: String; var size: Int; var kind: String; var from: String; var at: Int
}

func runTeam(_ args: [String]) -> Int32 {
    guard let sub = args.first, sub != "--help", sub != "-h" else {
        print(teamUsage(), terminator: "")
        return args.isEmpty ? 2 : 0
    }
    var positional: [String] = []
    var options: [String: String] = [:]
    let bareFlags: Set<String> = ["off", "show", "replace", "recovery", "rotate-identity"]
    var flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if bareFlags.contains(key) { flags.insert(key); i += 1; continue }
            // Every other team option takes a value; a bare flag is a typo,
            // not a boolean (`read --out` must never write to a file named "true").
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return fail("--\(key) needs a value\n\n\(teamUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }

    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)

    #if os(macOS)
    let ownDir = !(ProcessInfo.processInfo.environment["INFINITUS_TEAM_DIR"] ?? "").isEmpty
    if !ownDir {
        let socket = ControlProtocol.socketURL().path
        if let routed = routeToApp(sub, positional: positional, options: options, socket: socket) {
            return routed
        }
        // The app answers, this subcommand has no app verb, and no
        // in-process identity exists yet: minting one here would be
        // invisible to the app (#354). One that already exists keeps
        // working, with a note about which identity it is.
        if sub != "--help", sub != "help",
           ControlClient.roundTrip(ControlRequest(command: "team-status"), path: socket) != nil {
            if let kid = secrets.read(TeamClient.identitySecretName).flatMap({ try? TeamIdentity(secret: $0) })?.kid {
                FileHandle.standardError.write(Data("note: infinitusctl's own identity \(kid), not the app's — set INFINITUS_TEAM_DIR to silence this\n".utf8))
            } else {
                return fail("the Infinitus app owns this Mac's team identity (keychain), and `team \(sub)` has no app verb yet: use the app, or INFINITUS_TEAM_DIR=<dir> for a separate identity")
            }
        }
    }
    #endif

    func client() throws -> TeamClient {
        let ids = paths.teamIDs()
        let id = options["team"] ?? (ids.count == 1 ? ids[0] : nil)
        guard let id else {
            throw NSError(domain: "team", code: 1, userInfo: [NSLocalizedDescriptionKey:
                ids.isEmpty ? "no team on this machine (create or request one)" : "several teams: pass --team <id> (\(ids.joined(separator: ", ")))"])
        }
        // `--team` is interpolated into <base>/<id>/config.json.
        guard TeamClient.isPathSegment(id) else {
            throw NSError(domain: "team", code: 2, userInfo: [NSLocalizedDescriptionKey: "--team takes a team id (one path segment)"])
        }
        return try TeamClient.open(id: id, paths: paths, secrets: secrets)
    }

    do {
        switch sub {
        case "create":
            guard let name = positional.first, let remote = options["remote"] else { return fail(teamUsage(), code: 2) }
            guard options["token"] == nil || options["token"] == "-" else {
                return fail("--token takes only '-' (read from stdin)", code: 2)
            }
            var token: String?
            if options["token"] == "-" {
                token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if token?.isEmpty == true { token = nil }
            }
            let c = try TeamClient.create(name: name, remote: remote, token: token, leaderName: options["as"] ?? "Leader",
                                          paths: paths, secrets: secrets)
            emit(try c.status())
        case "code":
            let days = Int(options["days"] ?? "7") ?? 7
            let c = try client(); _ = try c.fetch()
            emit(["code": try c.code(expiresIn: days * 86_400)])
        case "request":
            guard let arg = positional.first, let name = options["name"] else { return fail(teamUsage(), code: 2) }
            let code: String
            if arg == "-" {
                code = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // The code embeds the store write credential; argv is world
                // readable. An expired code still carries a live one, so the
                // probe ignores expiry.
                if (try? TeamCode.decode(arg, now: Int.min))?.token != nil {
                    return fail("this code carries a credential: pass it on stdin (`team request -`)", code: 2)
                }
                code = arg
            }
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            #if os(macOS)
            let platform = "macos"
            #elseif os(Linux)
            let platform = "linux"
            #else
            let platform = "windows"
            #endif
            let c = try TeamClient.request(code: code, name: name, devices: devices, platform: platform,
                                           paths: paths, secrets: secrets)
            emit(try c.status())
        case "status":
            // Fetched first: a requester kept reading "pending" from the
            // cached roster after their approval (#354). Unreachable store
            // → the cached status, and stderr says so.
            func fresh(_ c: TeamClient) -> TeamStatus? {
                do { _ = try c.fetch() } catch {
                    FileHandle.standardError.write(Data("note: store unreachable (\(masked("\(error)"))); showing the cached status\n".utf8))
                }
                return try? c.status()
            }
            if options["team"] == nil, paths.teamIDs().count > 1 {
                emit(try paths.teamIDs().compactMap { fresh(try TeamClient.open(id: $0, paths: paths, secrets: secrets)) })
            } else {
                emit(try fresh(client()))
            }
        case "requests":
            let c = try client(); _ = try c.fetch()
            emit(try c.requests().map(\.doc))
        case "approve":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.approve(kid: kid); emit(try c.status())
        case "decline":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.decline(kid: kid); emit(try c.status())
        case "fetch":
            let c = try client(); _ = try c.fetch(); emit(try c.status())
        case "put":
            guard let kind = options["kind"], let path = options["path"], let file = options["file"] else { return fail(teamUsage(), code: 2) }
            let audience: TeamRoster.ShareTarget
            switch options["audience"] ?? "leaders" {
            case "leaders": audience = .leaders
            case "team": audience = .team
            case let kids: audience = .members(kids.split(separator: ",").map(String.init))
            }
            let c = try client(); _ = try c.fetch()
            let stored = try c.publish(kind: kind, path: path, plaintext: try Data(contentsOf: URL(fileURLWithPath: file)), audience: audience)
            emit(["path": stored])
        case "list":
            let c = try client(); _ = try c.fetch()
            // Headers only: `read` decrypts a whole envelope (a transcript
            // chunk is a megabyte) to print five fields. A blob whose
            // header will not parse is counted, not fatal (#55).
            struct Listing: Encodable { var entries: [ReadableEntry]; var skipped: Int }
            let scan = try c.readableScan()
            emit(Listing(entries: scan.headers.map {
                ReadableEntry(path: $0.entry.path, size: $0.entry.size, kind: $0.header.kind,
                              from: $0.header.from, at: $0.header.at)
            }, skipped: scan.skipped))
        case "read":
            guard let path = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch()
            let (_, plain) = try c.read(path)
            if let out = options["out"] { try plain.write(to: URL(fileURLWithPath: out)) }
            else { FileHandle.standardOutput.write(plain) }
        case "remove":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.remove(kid: kid)
            emit(try c.status())
        case "promote":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.promote(kid: kid); emit(try c.status())
        case "share":
            guard positional.count >= 2 else { return fail(teamUsage(), code: 2) }
            let kind = positional[0]
            guard TeamKinds.memberKinds.contains(kind) else {
                return fail("kind must be one of \(TeamKinds.memberKinds.joined(separator: ", "))", code: 2)
            }
            guard let target = TeamShares.parseTarget(Array(positional.dropFirst())) else { return fail(teamUsage(), code: 2) }
            let c = try client()
            if case .members(let kids) = target {
                // Named kids are checked against the roster as it is now, not the cached one.
                _ = try c.fetch()
                let known = Set(c.roster?.doc.everyone.map(\.keys.kid) ?? [])
                for kid in kids where !known.contains(kid) {
                    return fail("unknown kid \(kid)", code: 2)
                }
            }
            let teamDir = paths.teamDir(c.config.id)
            var shares = TeamShares.load(teamDir: teamDir)
            shares.byKind[kind] = target
            try shares.save(teamDir: teamDir)
            emit(shares)
        case "leave":
            // Spec §6.5: the store side, then forget the team locally
            // (dir + token). The identity stays unless --rotate-identity.
            let c = try client()
            try c.leave(rotateIdentity: flags.contains("rotate-identity"))
            secrets.delete(TeamClient.tokenName(c.config.id))
            try? FileManager.default.removeItem(at: paths.teamDir(c.config.id))
            emit(["left": c.config.id, "kid": try TeamClient.identity(paths: paths, secrets: secrets).kid])
        case "exclude":
            guard let raw = positional.first else { return fail(teamUsage(), code: 2) }
            let project = URL(fileURLWithPath: raw).standardizedFileURL.path
            var exclusions = TeamExclusions.load(paths: paths)
            exclusions.set(project, excluded: !flags.contains("off"))
            try exclusions.save(paths: paths)
            emit(exclusions)
        case "identity":
            // Spec §2.1: the local identity's kid, its recovery key, and a
            // passphrase-sealed export/import. Passphrases and keys come on
            // stdin (never argv); the secret is printed only as the
            // recovery key, on an explicit --show.
            let what = positional.first ?? "show"
            func stdinLine() -> String {
                String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            switch what {
            case "show":
                guard let kid = secrets.read(TeamClient.identitySecretName).flatMap({ try? TeamIdentity(secret: $0) })?.kid else {
                    return fail("no identity on this machine yet — it is created on the first create/request/export", code: 1)
                }
                emit(["kid": kid])
            case "recovery":
                guard flags.contains("show") else { return fail("team identity recovery --show prints the key: keep it offline", code: 2) }
                let me = try TeamClient.identity(paths: paths, secrets: secrets)
                emit(["kid": me.kid, "recoveryKey": RecoveryKey.encode(me.secret)])
            case "export":
                let passphrase = stdinLine()
                guard passphrase.count >= 8 else { return fail("passphrase on stdin, at least 8 characters", code: 2) }
                let me = try TeamClient.identity(paths: paths, secrets: secrets)
                let file = try TeamIdentityExport.export(secret: me.secret, passphrase: passphrase)
                if let out = options["out"] {
                    let url = URL(fileURLWithPath: out)
                    do {
                        try TeamIdentityExport.write(file, to: url)
                    } catch TeamIdentityExport.WriteError.exists {
                        return fail("\(url.path) exists; pick another path", code: 2)
                    }
                    emit(["kid": me.kid, "out": url.path])
                } else {
                    print(String(decoding: file, as: UTF8.self))
                }
            case "import":
                if secrets.read(TeamClient.identitySecretName) != nil, !flags.contains("replace") {
                    return fail("an identity exists; pass --replace to overwrite it (teams that approved the old kid must re-approve)", code: 2)
                }
                let secret: Data
                if flags.contains("recovery") {
                    guard let s = RecoveryKey.decode(stdinLine()) else { return fail("that is not a recovery key", code: 2) }
                    secret = s
                } else {
                    guard positional.count >= 2 else { return fail(teamUsage(), code: 2) }
                    let file = try Data(contentsOf: URL(fileURLWithPath: positional[1]))
                    secret = try TeamIdentityExport.import(file, passphrase: stdinLine())
                }
                try secrets.write(TeamClient.identitySecretName, secret)
                emit(["kid": try TeamIdentity(secret: secret).kid])
            default:
                return fail(teamUsage(), code: 2)
            }
        case "policy":
            let c = try client(); _ = try c.fetch()
            guard var policy = c.roster?.doc.policy else { throw TeamClient.ClientError.noRoster }
            var changed = false
            if let r = options["requests"] {
                guard ["code", "off"].contains(r) else { return fail("--requests is code or off", code: 2) }
                policy.requests = r; changed = true
            }
            if let m = options["members-see-each-other"] {
                guard ["on", "off"].contains(m) else { return fail("--members-see-each-other is on or off", code: 2) }
                policy.membersSeeEachOther = m == "on"; changed = true
            }
            if changed { try c.setPolicy(policy) }
            emit(policy)
        default:
            return fail("unknown team subcommand \(sub)\n\n\(teamUsage())", code: 2)
        }
        return 0
    } catch {
        return fail("\(error)")
    }
}
