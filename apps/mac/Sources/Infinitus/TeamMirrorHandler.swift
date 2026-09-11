import Foundation
import InfinitusCore

/// Dispatches `/mirror/team/*` (spec §9 step 8) onto TeamModel. Every
/// reply is JSON; nil is a 404. Actions run the same gated TeamModel
/// methods the pane uses, so the biometric gate and error masking apply
/// unchanged — a failure comes back as `ActionReply(ok: false, error:)`
/// carrying the error of the call that just ran, never as a raw git message.
@MainActor
enum TeamMirrorHandler {
    static func reply(_ r: MirrorTransport.Request, team: TeamModel) async -> Data? {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ v: T) -> Data? { try? encoder.encode(v) }
        func action(_ body: () async -> String?) async -> Data? {
            team.clearError()
            // The call's OWN error: `team.lastError` can hold an older
            // failure, or a reload's, and the phone would show that instead.
            let failure = await body()
            return json(TeamMirror.ActionReply(ok: failure == nil, error: failure))
        }
        switch (r.method, r.path) {
        case ("GET", TeamMirror.aggregatesPath):
            return json(team.reader?.aggregates ?? [:])
        case ("GET", TeamMirror.memberPath):
            guard let kid = r.query("kid"), let reader = team.reader, let m = reader.members[kid] else { return nil }
            let period = r.query("period").flatMap(Stats.Period.init(rawValue:)) ?? .week
            return json(TeamMirror.MemberReply(kid: kid, name: m.name, summary: reader.summary(kid: kid, period: period)?.compacted(),
                                               sessions: m.sessions, transcripts: Array(m.transcripts.keys).sorted()))
        case ("GET", TeamMirror.transcriptPath):
            guard let kid = r.query("kid"), let session = r.query("session") else { return nil }
            return json(await team.transcript(kid: kid, session: session))
        case ("POST", TeamMirror.approvePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            return await action { await team.approve(kid: body.kid) }
        case ("POST", TeamMirror.declinePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return nil }
            return await action { await team.decline(kid: body.kid) }
        case ("POST", TeamMirror.joinPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.JoinRequest.self, from: r.body) else { return nil }
            return await action { await team.join(code: body.code, name: body.name) }
        case ("POST", TeamMirror.codePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.CodeRequest.self, from: r.body),
                  (1...30).contains(body.days) else { return nil }
            team.clearError()
            if body.invite { await team.mintInvite(days: body.days) } else { await team.mintCode(days: body.days) }
            // A failed mint leaves `code` untouched, so read it only on
            // success or the pane's open code would ship as the phone's.
            let code = team.lastError == nil ? team.code : nil
            if code != nil { team.clearCode() }   // the pane's QR must not pop because the phone asked
            return json(TeamMirror.ActionReply(ok: code != nil, error: team.lastError, code: code))
        default:
            // Nearby (spec §6.4) has its own file; nil from there is a real 404.
            return await TeamMirrorNearby.handle(r, team: team)
        }
    }
}
