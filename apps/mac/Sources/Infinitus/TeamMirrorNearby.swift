import Foundation
import InfinitusCore

/// The phone's Nearby (spec §6.4 last bullet): `/mirror/team/nearby*`
/// onto the very TeamModel methods the Mac pane's Nearby sections call,
/// so there is one policy and one error path. Its own file to keep
/// TeamMirrorHandler's switch one concern wide; `nil` means "not one of
/// mine" and the handler's `default` turns that into a 404 — a route
/// that IS one of mine but carries a body it can't decode answers
/// `ActionReply(ok: false, …)` instead, never `nil`. Every reply is a
/// JSON body — MirrorServer wraps it (`MirrorTransport.jsonResponse`).
@MainActor
enum TeamMirrorNearby {
    static func handle(_ r: MirrorTransport.Request, team: TeamModel) async -> Data? {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ v: T) -> Data? { try? encoder.encode(v) }
        func action(_ body: () async -> Void) async -> Data? {
            team.clearError()
            await body()
            return json(TeamMirror.ActionReply(ok: team.lastError == nil, error: team.lastError))
        }
        func gone() -> Data? { json(TeamMirror.ActionReply(ok: false, error: "that invitation is gone")) }
        /// A route that IS ours but whose body doesn't decode: reported
        /// as a bad request, not `nil` — `nil` is the handler's "not one
        /// of mine" signal and turns into a 404 at the default case.
        func badBody() -> Data? { json(TeamMirror.ActionReply(ok: false, error: "bad request body")) }
        /// Names and kids only — no code, no token, no envelope (spec §10).
        func lists() -> TeamMirror.NearbyReply {
            TeamMirror.NearbyReply(
                peers: team.nearby,
                pending: team.pendingNearby.map {
                    TeamMirror.PendingRequest(kid: $0.doc.keys.kid, name: $0.doc.name,
                                              platform: $0.doc.platform, at: $0.doc.at)
                },
                invites: team.invites.map {
                    TeamMirror.InviteSummary(fromKid: $0.from.kid, fromName: $0.fromName, teamName: $0.teamName)
                },
                team: team.snapshot?.id)
        }
        switch (r.method, r.path) {
        case ("GET", TeamMirror.nearbyPath):
            // An invitation can arrive without a scan, so read that
            // directory before answering; peers come from the last browse.
            await team.loadInvites()
            return json(lists())
        case ("POST", TeamMirror.nearbyScanPath):
            // A 2 s mDNS browse on the team queue, then the same lists.
            await team.scanNearby()
            return json(lists())
        case ("POST", TeamMirror.nearbyRequestPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.NearbyJoinRequest.self, from: r.body) else { return badBody() }
            guard let peer = team.nearby.first(where: { $0.kid == body.kid }) else {
                return json(TeamMirror.ActionReply(ok: false, error: "that machine is no longer on this network"))
            }
            return await action { await team.requestNearby(peer, name: body.name) }
        case ("POST", TeamMirror.nearbyInvitePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return badBody() }
            guard let peer = team.nearby.first(where: { $0.kid == body.kid }) else {
                return json(TeamMirror.ActionReply(ok: false, error: "that machine is no longer on this network"))
            }
            return await action { await team.inviteNearby(peer) }
        case ("POST", TeamMirror.nearbyPullPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return badBody() }
            guard let signed = team.pendingNearby.first(where: { $0.doc.keys.kid == body.kid }) else {
                return json(TeamMirror.ActionReply(ok: false, error: "that request is gone"))
            }
            return await action { await team.pullNearbyRequest(signed) }
        case ("POST", TeamMirror.nearbyAcceptPath):
            guard let body = try? JSONDecoder().decode(TeamMirror.InviteAccept.self, from: r.body) else { return badBody() }
            await team.loadInvites()
            guard let invite = team.invites.first(where: { $0.from.kid == body.fromKid }) else { return gone() }
            return await action { await team.acceptInvite(invite, name: body.name) }
        case ("POST", TeamMirror.nearbyIgnorePath):
            guard let body = try? JSONDecoder().decode(TeamMirror.KidRequest.self, from: r.body) else { return badBody() }
            await team.loadInvites()
            guard let invite = team.invites.first(where: { $0.from.kid == body.kid }) else { return gone() }
            return await action { await team.ignoreInvite(invite) }
        default:
            return nil
        }
    }
}
