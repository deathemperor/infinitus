import Foundation
import InfinitusCore

// `infinitusctl team …` runs in-process — no control socket, so a Linux
// or Windows member needs only this binary (spec §9). State lives under
// TeamPaths.standard() (override: INFINITUS_TEAM_DIR); secrets in
// FileSecrets under it — the Mac app's keychain store arrives in plan 5.

func teamUsage() -> String {
    """
    usage: infinitusctl team <subcommand> [args] [--option value]

      create <name> --remote <url> [--token -] [--as <your name>]     create a team on an empty git remote (token from stdin)
      code [--days N]                              team code for joiners (default 7 days)
      request - --name <n> [--devices a,b]         ask to join; the code on stdin (argv only if it carries no credential)
      status [--team <id>]                         this machine's team(s)
      requests                                     pending join requests (leaders)
      approve <kid> | decline <kid>                answer a request (leaders)
      remove <kid> | promote <kid>                 roster edits (leaders; the founder cannot be removed)
      fetch                                        pull the store and accept the roster
      members [--period <p>]              every member's period totals (spend is an estimate), online, blockers, when they joined, and what they share with you
      member <kid> [--period day|week|month|year]  one member's Stats summary (default week)
      insights [--period <p>]             leaderboards, repo coverage, blockers board, cost by member/model/repo, who's on, hours
      aggregates                          the leaders' published team picture
      aggregates publish [--period all|<p>]   (leaders) publish the team picture to the whole team
      policy [--requests code|off] [--members-see-each-other on|off]   (leaders) show or set the roster policy
      share <kind> off|leaders|team|<kid>[,<kid>…]  audience for stats|now|sessions|transcripts|crashes|fleet ("off" keeps it on this machine; new envelopes — see reshare)
      leave [--rotate-identity]                    delete my files on the store, tell the leaders, forget the team here (and mint a new identity)
      exclude <project-dir> [--off]                keep a Claude Code project private (local, never sent)
      identity [show]                    this machine's identity kid
      identity recovery --show           the recovery key (base32, 8 groups) — keep it offline
      identity export [--out <file>]     passphrase on stdin (≥ 8 chars); the sealed file to --out (0600) or stdout
      identity import <file> | --recovery [--replace]   passphrase or recovery key on stdin
      publish [--projects <dir>] [--days N]        publish stats, now, sessions, redacted transcripts, crashes (default 30 days)
      reshare [--days N]                           re-wrap the last N days (default 30) to the current audiences
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

private struct ReadableEntry: Encodable {
    var path: String; var size: Int; var kind: String; var from: String; var at: Int
}

private struct MemberRow: Encodable {
    var kid: String; var name: String; var role: String; var online: Bool
    var sessionsNow: Int; var blockers: [String]; var crashes: Int; var lastPublished: Int?
    var usd: Double; var commits: Int; var messages: Int; var outputTokens: Int; var sessions: Int
    var sharesToMe: [String]
    /// Unix seconds: roster approval; `removedAt` for a removed sender still readable.
    var joined: Int?; var removedAt: Int?
}

func runTeam(_ args: [String]) -> Int32 {
    if let code = runTeamNearby(args) { return code }   // nearby | --discoverable | request --nearby (TeamNearbyCommand.swift)
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

    // Team gate (spec §2.2): starting, joining or admitting into a team
    // needs the biometric lock on wherever a lock exists — the Mac app's
    // setting, read from its prefs domain. Linux is open until its
    // passphrase lock ships; INFINITUS_LOCK_GATE=open is the CI/dev hatch
    // (TeamGate.swift).
    if (["create", "request", "approve", "policy"].contains(sub)
        || (sub == "identity" && ["recovery", "export"].contains(positional.first ?? ""))),
       case .needsLock(let why) = TeamGate.check(lockEnabled: LockSetting.enabledOnThisMachine()) {
        return fail("\(why) (Infinitus › Settings › Lock)")
    }

    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)

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
            if options["team"] == nil, paths.teamIDs().count > 1 {
                emit(try paths.teamIDs().map { try TeamClient.open(id: $0, paths: paths, secrets: secrets).status() })
            } else {
                emit(try client().status())
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
            let c = try client(); _ = try c.fetch(); try c.remove(kid: kid); emit(try c.status())
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
        case "members":
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            let reader = try TeamReader.load(client: c)
            let roster = c.roster?.doc
            let shared = Dictionary(uniqueKeysWithValues: (roster.map { TeamInsights.sharedWithMe(reader, roster: $0, me: c.identity.kid) } ?? []).map { ($0.kid, $0.kinds) })
            emit(TeamInsights.comparison(reader, period: period).map { r in
                MemberRow(kid: r.kid, name: r.name, role: r.role, online: r.online, sessionsNow: r.sessionsNow, blockers: r.blockers,
                          crashes: r.crashes, lastPublished: r.lastPublished, usd: r.summary.total.usd, commits: r.summary.total.commits,
                          messages: r.summary.total.messages, outputTokens: r.summary.total.outputTokens,
                          sessions: r.summary.total.sessionCount, sharesToMe: shared[r.kid] ?? [], joined: r.since, removedAt: r.removedAt)
            })
        case "member":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            guard let summary = try TeamReader.load(client: c).summary(kid: kid, period: period) else {
                return fail("nothing readable from \(kid)")
            }
            emit(summary.compacted())
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
        case "publish":
            let c = try client(); _ = try c.fetch()
            let claudeDir = ClaudeSessions.configHome()
            var sources = TeamPublisher.Sources(
                projectsDir: options["projects"].map { URL(fileURLWithPath: $0) } ?? claudeDir.appendingPathComponent("projects"),
                home: NSHomeDirectory())
            // `--projects` only swaps the Claude Code projects dir and skips the
            // Codex scan; live sessions, the scan cache and crashes still come
            // from this machine regardless.
            sources.codexDir = options["projects"] == nil ? StatsScanner.defaultCodexDir() : nil
            sources.cacheURL = paths.teamDir(c.config.id).appendingPathComponent("scan-cache.json")
            sources.liveSessions = ClaudeSessions.list(claudeDir: claudeDir)
            sources.crashes = CrashStore(directory: CrashStore.defaultDirectory()).list()
            if let days = options["days"].flatMap(Int.init) { sources.historyDays = days }
            emit(try TeamPublisher(client: c, paths: paths).publish(sources: sources))
        case "reshare":
            let c = try client(); _ = try c.fetch()
            let days = options["days"].flatMap(Int.init) ?? 30
            emit(try TeamPublisher(client: c, paths: paths).reshare(days: days))
        case "insights":
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            let reader = try TeamReader.load(client: c)
            let rows = TeamInsights.comparison(reader, period: period)
            let repos = TeamInsights.repos(reader, period: period)
            let cost = TeamInsights.cost(rows, repos: repos)
            struct Board: Encodable { var kid, name, kind, text: String }
            struct Repo: Encodable { var project: String; var usd: Double; var minutes: Int; var members: [String] }
            struct Row: Encodable { var kid, name: String; var value: Double }
            struct Money: Encodable { var kid, name: String; var usd: Double }
            struct Costs: Encodable { var total: Double; var byMember: [Money]; var byModel: [String: Double]; var byRepo: [String: Double] }
            struct Insights: Encodable {
                var period, from, to: String
                var leaderboards: [String: [Row]]
                var repos: [Repo]
                var blockers: [Board]
                var cost: Costs
                var onNow: [String]
                var hours: [Int]
            }
            let sample = rows.first?.summary
            emit(Insights(
                period: period.rawValue, from: sample?.from ?? "", to: sample?.to ?? "",
                leaderboards: Dictionary(uniqueKeysWithValues: TeamInsights.Metric.allCases.map { m in
                    (m.rawValue, TeamInsights.leaderboard(rows, metric: m).map { Row(kid: $0.kid, name: $0.name, value: $0.value) }) }),
                repos: repos.map { Repo(project: $0.project, usd: $0.usd, minutes: $0.minutes, members: $0.members.map(\.name)) },
                blockers: TeamInsights.blockers(reader).map { Board(kid: $0.kid, name: $0.name, kind: $0.kind, text: $0.text) },
                cost: Costs(total: cost.total, byMember: cost.byMember.map { Money(kid: $0.kid, name: $0.name, usd: $0.usd) },
                            byModel: cost.byModel, byRepo: cost.byRepo),
                onNow: TeamInsights.whoIsOn(reader).map(\.name), hours: TeamInsights.hours(rows)))
        case "aggregates":
            let c = try client(); _ = try c.fetch()
            if positional.first == "publish" {
                guard let roster = c.roster?.doc else { throw TeamClient.ClientError.noRoster }
                let which = options["period"] ?? "all"
                let periods = which == "all" ? Stats.Period.allCases : [Stats.Period(rawValue: which)].compactMap { $0 }
                guard !periods.isEmpty else { return fail("--period is all, day, week, month or year", code: 2) }
                let reader = try TeamReader.load(client: c)
                var docs: [String: Data] = [:]
                for p in periods { docs[p.rawValue] = try CanonicalJSON.encode(TeamInsights.aggregates(reader, roster: roster, period: p)) }
                emit(["published": try c.publishAggregates(docs)])
            } else {
                emit(try TeamReader.load(client: c).aggregates)
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
