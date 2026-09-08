import ActivityKit
import Foundation
import InfinitusCore
import os

/// Drives the two Live Activities (#1 all-dead countdown, #2 working
/// sessions) from each mirror refresh while the app runs, and hands
/// their APNs tokens to the Mac so it can keep them moving (and start
/// them, iOS 17.2+) with the app closed — LiveActivityPusher on the Mac.
/// Content is built by InfinitusCore's `LiveActivityBuilder`, the same
/// code the Mac's pushes use, themed with the phone's theme.
///
/// One pair of cards per paired Mac (#144), keyed by the Mac's name —
/// the `machine` attribute every card already carries, the Mac's own
/// name that `MirrorModel.refreshOthers` keeps the pairing's name equal
/// to. A card's update token goes to the Mac it belongs to; the
/// per-phone tokens (push-to-start, alerts) go to every paired Mac.
@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    private let log = Logger(subsystem: "run.infinitus.mobile", category: "live-activity")
    private var revival: [String: Activity<RevivalActivity>] = [:]
    private var working: [String: Activity<WorkingActivity>] = [:]
    private var tokenWatchers: [String: Task<Void, Never>] = [:]
    /// The per-phone tokens as last seen, re-sent to a Mac that comes
    /// within reach after they arrived.
    private var phoneTokens: [ActivityPushRegistration.Kind: Data] = [:]
    private var themeID: String?
    /// What the widgets draw, per Mac (#144), by pairing id.
    private var widgetPayloads: [String: WidgetBridge.Payload] = [:]
    /// The primary Mac accepted this phone's alert token — its APNs
    /// alerts reach here, so the local swap banner (#86) stands down.
    private(set) var alertTokenRegistered = false
    /// Logged once per stretch of old snapshots, not every 10 s.
    private var skippingOld: Set<String> = []

    private init() {
        // Adopt activities that survived an app relaunch (or that a Mac
        // started by push while the app was closed), one per Mac.
        for machine in Set(Activity<RevivalActivity>.activities.map(\.attributes.machine)) {
            revival[machine] = Self.adopt(Activity<RevivalActivity>.activities, machine: machine)
            if let activity = revival[machine] { watchToken(of: activity, kind: .revival, machine: machine) }
        }
        for machine in Set(Activity<WorkingActivity>.activities.map(\.attributes.machine)) {
            working[machine] = Self.adopt(Activity<WorkingActivity>.activities, machine: machine)
            if let activity = working[machine] { watchToken(of: activity, kind: .working, machine: machine) }
        }
        watchPushToStartTokens()
    }

    /// `macId`: the Mac's pairing id, nil for the primary.
    func sync(fleet: MirrorFleetModel?, machine: String, tokenRate: TokenRate?, capturedAt: Date,
              macId: String? = nil) {
        guard let fleet else { return }
        let engineFleet = EngineFleet(engineID: fleet.id, provider: fleet.provider, accounts: fleet.accounts,
                                      activeNumber: fleet.activeNumber, nextCandidate: fleet.nextCandidate,
                                      nextRecovery: fleet.nextRecovery, liveSessions: fleet.liveSessions, raw: nil)
        let revivalState = LiveActivityBuilder.revival(fleet: engineFleet, theme: fleet.rowTheme)
        let workingState = LiveActivityBuilder.working(fleet: engineFleet, theme: fleet.rowTheme,
                                                       report: fleet.report, tokenRate: tokenRate)
        // The widgets (#80) draw the same states, activities enabled or
        // not; `publishWidgets` hands them over once per poll.
        widgetPayloads[macId ?? WidgetBridge.primary] = .init(
            id: macId ?? WidgetBridge.primary, working: workingState, revival: revivalState,
            machine: machine, capturedAt: capturedAt)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.notice("live activities disabled for this app")
            return
        }
        themeID = fleet.rowTheme.id
        // A push may have started/ended one behind our back, and a card
        // past its stale date is still ours: `.stale` is not `.active`,
        // and adopting only the latter requested a second card while the
        // old one stayed on the lock screen with the old account.
        working[machine] = Self.adopt(Activity<WorkingActivity>.activities, machine: machine,
                                      current: working[machine])
        revival[machine] = Self.adopt(Activity<RevivalActivity>.activities, machine: machine,
                                      current: revival[machine])
        // The revival card runs on the wall clock (its builder ends it once
        // the reset instant passes), so an old snapshot still drives it.
        syncRevival(revivalState, machine: machine)
        // The working card names the active account, and an old snapshot
        // — the Documents fallback when the Mac is out of reach — names
        // whichever one was active when the phone last heard from it; it
        // waits for a fresh one (user 2026-09-05: the card still showed
        // the old account after the Mac had switched).
        guard Date().timeIntervalSince(capturedAt) < LiveActivityBuilder.workingStale else {
            if !skippingOld.contains(machine) {
                log.notice("snapshot from \(capturedAt) is too old to drive \(machine)'s working activity")
            }
            skippingOld.insert(machine)
            return
        }
        skippingOld.remove(machine)
        syncWorking(workingState, machine: machine)
    }

    /// The widgets' payloads, primary first — once per poll, after every
    /// Mac was asked; a Mac no longer in `ids` was forgotten.
    func publishWidgets(keeping ids: Set<String>) {
        widgetPayloads = widgetPayloads.filter { ids.contains($0.key) }
        // Nothing synced yet this run (a fresh process whose primary has
        // not answered): the widgets keep what they last drew.
        guard !widgetPayloads.isEmpty else { return }
        let others = widgetPayloads.values.filter { $0.id != WidgetBridge.primary }
            .sorted { $0.machine < $1.machine }
        WidgetBridge.publish([widgetPayloads[WidgetBridge.primary]].compactMap { $0 } + others)
    }

    /// A Mac forgotten (#144): its cards go with the pairing.
    func end(machine: String) {
        for activity in Activity<RevivalActivity>.activities where activity.attributes.machine == machine {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        for activity in Activity<WorkingActivity>.activities where activity.attributes.machine == machine {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        revival[machine] = nil
        working[machine] = nil
        for kind in [ActivityPushRegistration.Kind.revival, .working] {
            tokenWatchers.removeValue(forKey: "\(machine)/\(kind.rawValue)")?.cancel()
        }
    }

    // MARK: #1

    private func syncRevival(_ state: RevivalActivityState?, machine: String) {
        let revival = revival[machine]
        if let state {
            let content = ActivityContent(state: state, staleDate: state.revivesAt.addingTimeInterval(60))
            if let revival, Self.isLive(revival) {
                if revival.activityState == .stale || revival.content.state != state {
                    Task { await revival.update(content) }
                }
            } else {
                do {
                    let (activity, pushed) = try request(attributes: RevivalActivity(machine: machine), content: content)
                    self.revival[machine] = activity
                    if pushed { watchToken(of: activity, kind: .revival, machine: machine) }
                    log.notice("revival activity started on \(machine): \(state.reviver) at \(state.revivesAt)")
                } catch {
                    log.error("revival activity refused: \(error.localizedDescription)")
                }
            }
        } else if let revival, Self.isLive(revival) {
            // Back from the dead: a brief "revived" card, then gone.
            var final = revival.content.state
            final.revived = true
            self.revival[machine] = nil
            Task {
                await revival.end(ActivityContent(state: final, staleDate: nil),
                                  dismissalPolicy: .after(Date().addingTimeInterval(120)))
            }
        }
    }

    // MARK: #2

    private func syncWorking(_ state: WorkingActivityState?, machine: String) {
        let working = working[machine]
        if let state {
            let content = ActivityContent(state: state,
                                          staleDate: Date().addingTimeInterval(LiveActivityBuilder.workingStale))
            if let working, Self.isLive(working) {
                if working.activityState == .stale || LiveActivityBuilder.differs(working.content.state, state)
                    || working.content.state.tokensPerMinute != state.tokensPerMinute {
                    Task { await working.update(content) }
                }
            } else {
                do {
                    let (activity, pushed) = try request(attributes: WorkingActivity(machine: machine), content: content)
                    self.working[machine] = activity
                    if pushed { watchToken(of: activity, kind: .working, machine: machine) }
                    log.notice("working activity started on \(machine): \(state.active) \(state.busy)/\(state.total)")
                } catch {
                    log.error("working activity refused: \(error.localizedDescription)")
                }
            }
        } else if let working, Self.isLive(working) {
            self.working[machine] = nil
            Task { await working.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Active, or past its stale date and still on the lock screen.
    private static func isLive<A: ActivityAttributes>(_ activity: Activity<A>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    /// The one card of a type to keep driving for a Mac — the current one
    /// while it lives, else an active one, else a stale one — with every
    /// other live card of that type for the same Mac ended: two on the
    /// lock screen is how a switch went unseen. Another Mac's cards are
    /// not this Mac's business (#144).
    private static func adopt<A: MacCard>(_ all: [Activity<A>], machine: String,
                                          current: Activity<A>? = nil) -> Activity<A>? {
        let live = all.filter { $0.attributes.machine == machine && isLive($0) }
        // The current card stays even before `activities` lists it (it
        // was requested a moment ago) — else this would request a twin.
        let keep = current.flatMap { isLive($0) ? $0 : nil }
            ?? live.first { $0.activityState == .active } ?? live.first
        for extra in live where extra.id != keep?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        return keep
    }

    /// With a push token where the build can have one, plain otherwise:
    /// a build without the aps-environment entitlement (a personal
    /// team's) has ActivityKit refuse every `.token` request outright
    /// ("ActivityInput error 0"), which is how the lock screen went
    /// blank after the APNs work (user 2026-09-04 "not seeing the ios
    /// live activities anymore"). Second value: whether a token comes.
    private func request<A: ActivityAttributes>(attributes: A, content: ActivityContent<A.ContentState>)
        throws -> (Activity<A>, Bool) {
        if let activity = try? Activity.request(attributes: attributes, content: content, pushType: .token) {
            return (activity, true)
        }
        return (try Activity.request(attributes: attributes, content: content, pushType: nil), false)
    }

    // MARK: push tokens → the Mac

    private func watchToken<A: ActivityAttributes>(of activity: Activity<A>, kind: ActivityPushRegistration.Kind,
                                                   machine: String) {
        let key = "\(machine)/\(kind.rawValue)"
        tokenWatchers[key]?.cancel()
        tokenWatchers[key] = Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                await self?.register(kind: kind, token: token, machine: machine)
            }
        }
    }

    /// iOS 17.2+: one token per activity type that lets the Mac START an
    /// activity while the app is closed.
    private func watchPushToStartTokens() {
        guard #available(iOS 17.2, *) else { return }
        tokenWatchers["working-start"] = Task { [weak self] in
            for await token in Activity<WorkingActivity>.pushToStartTokenUpdates {
                await self?.register(kind: .workingStart, token: token)
            }
        }
        tokenWatchers["revival-start"] = Task { [weak self] in
            for await token in Activity<RevivalActivity>.pushToStartTokenUpdates {
                await self?.register(kind: .revivalStart, token: token)
            }
        }
    }

    /// A card's update token goes to the Mac whose card it is (`machine`);
    /// a per-phone token (push-to-start, alert) goes to every paired Mac,
    /// so any of them can start a card or alert this phone. Only the
    /// primary's answer decides `alertTokenRegistered`: FleetAlarmCenter
    /// pairs it with the primary snapshot's `pushesAlerts`.
    func register(kind: ActivityPushRegistration.Kind, token: Data, machine: String? = nil) async {
        let registration = registration(kind: kind, token: token)
        let model = MirrorModel.shared
        if let machine {
            let ok = await model.mirror(machine: machine).registerActivityToken(registration)
            log.notice("\(kind.rawValue) token \(ok ? "registered with" : "NOT registered — unreachable:") \(machine)")
            return
        }
        phoneTokens[kind] = token
        let ok = await NetworkFleetMirror.shared.registerActivityToken(registration)
        if kind == .alert { alertTokenRegistered = ok }
        log.notice("\(kind.rawValue) token \(ok ? "registered with the Mac" : "NOT registered — Mac unreachable")")
        // A Mac that has never answered would cost a timeout each; it gets
        // the tokens on its first answer (`resendPhoneTokens`).
        for mac in model.others where mac.snapshot != nil && !mac.parked {
            let ok = await model.mirror(for: mac.id).registerActivityToken(registration)
            log.notice("\(kind.rawValue) token \(ok ? "registered with" : "NOT registered — unreachable:") \(mac.pairing.name)")
        }
    }

    /// A Mac that just came within reach gets the per-phone tokens it
    /// missed while it was away (or before it was paired).
    func resendPhoneTokens(macId: String) async {
        let mirror = MirrorModel.shared.mirror(for: macId)
        for (kind, token) in phoneTokens {
            _ = await mirror.registerActivityToken(registration(kind: kind, token: token))
        }
    }

    private func registration(kind: ActivityPushRegistration.Kind, token: Data) -> ActivityPushRegistration {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        return ActivityPushRegistration(
            kind: kind, token: token.map { String(format: "%02x", $0) }.joined(),
            deviceId: NetworkFleetMirror.deviceId, deviceName: NetworkFleetMirror.deviceName,
            environment: environment, themeID: themeID)
    }
}
