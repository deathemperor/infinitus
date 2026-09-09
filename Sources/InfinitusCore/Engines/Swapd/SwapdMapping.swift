import Foundation

// MARK: - swapd list --json (contract v1)
//
// Field names mirror swapd's `src/contract.rs` verbatim (camelCase), so
// JSONDecoder needs no key strategy. Every Optional there is
// `skip_serializing_if = "Option::is_none"`: a missing value is an ABSENT
// key, never a null, which is why each one decodes as `T?` and nothing
// here treats null specially.
//
// Countdown and clock strings are deliberately NOT in the contract (spec
// §4: "the app formats") — SwapdMapping computes them, the same way the
// proxy engine does.

public struct SwapdList: Decodable, Sendable {
    public let schemaVersion: Int
    public let providers: [SwapdProviderView]
}

public struct SwapdProviderView: Decodable, Sendable {
    /// The engine's own provider id ("claude", "codex", …).
    public let provider: String
    public let installed: Bool
    public let activeSlot: Int?
    public let nextCandidate: Int?
    public let nextRecovery: SwapdRecovery?
    public let accounts: [SwapdAccountView]
}

public struct SwapdRecovery: Decodable, Sendable {
    public let slot: Int
    public let at: String
}

public struct SwapdAccountView: Decodable, Sendable {
    public let slot: Int
    public let email: String
    public let organizationName: String
    public let organizationUuid: String
    public let plan: String?
    public let alias: String?
    public let icon: String?
    public let active: Bool
    public let disabled: Bool
    public let preferred: Bool
    public let usageStatus: String
    public let fetchedAt: String?
    public let ageSeconds: Double?
    public let windows: [SwapdWindow]
    /// Only when the live fetch failed and an older good fetch exists.
    public let lastGood: SwapdLastGood?
}

public struct SwapdLastGood: Decodable, Sendable {
    public let fetchedAt: String
    public let ageSeconds: Double
    public let windows: [SwapdWindow]
}

public struct SwapdWindow: Decodable, Sendable {
    /// `5h | 7d | daily | monthly | scoped | spend`.
    public let kind: String
    /// Display name — scoped windows only.
    public let name: String?
    public let pct: Double
    public let resetsAt: String?
    public let pace: SwapdPace?
    public let used: Double?
    public let limit: Double?
    public let currency: String?
}

public struct SwapdPace: Decodable, Sendable {
    public let expectedPct: Double
    public let ahead: Bool
    public let exhaustsAt: String?
    public let lastsToReset: Bool
}

/// The error envelope every verb prints on stdout under `--json` before it
/// exits non-zero (swapd `src/output.rs`). `code` is a stable token
/// (`no-such-slot`, `locked`, `unsupported`, …).
public struct SwapdErrorEnvelope: Decodable, Sendable {
    public struct Body: Decodable, Sendable {
        public let code: String
        public let message: String
    }
    public let schemaVersion: Int
    public let error: Body
}

/// Pure `list --json` → neutral models. Separate from the CLI so the whole
/// mapping is testable from a fixture, with no subprocess anywhere.
public enum SwapdMapping {
    public static let engineID = "swapd"
    /// The contract version this build reads. swapd's schema is
    /// additive-stable: new fields never bump it, a shape change does.
    public static let schemaVersion = 1

    /// swapd's provider id in the app's vocabulary; an id this build
    /// predates lands in `.other` rather than failing the whole snapshot.
    public static func provider(for raw: String) -> Provider {
        Provider(rawValue: raw.lowercased()) ?? .other
    }

    /// One fleet per provider that HOLDS accounts. A provider swapd only
    /// reports because its CLI is installed has nothing to render, and an
    /// empty fleet would sit in the popup as an empty section.
    public static func fleets(from list: SwapdList, engineID: String = engineID,
                              now: Date = Date()) -> [EngineFleet] {
        var seen: Set<Provider> = []
        var fleets: [EngineFleet] = []
        for view in list.providers where !view.accounts.isEmpty {
            let provider = provider(for: view.provider)
            // Two unknown providers would both key on "swapd/other" and the
            // registry holds one state per key: the first one wins.
            guard seen.insert(provider).inserted else { continue }
            fleets.append(fleet(from: view, provider: provider, engineID: engineID, now: now))
        }
        return fleets
    }

    public static func fleet(from view: SwapdProviderView, provider: Provider? = nil,
                             engineID: String = engineID, now: Date = Date()) -> EngineFleet {
        EngineFleet(engineID: engineID,
                    provider: provider ?? self.provider(for: view.provider),
                    accounts: view.accounts.map { account($0, now: now) },
                    activeNumber: view.activeSlot,
                    nextCandidate: view.nextCandidate,
                    nextRecovery: view.nextRecovery.map { NextRecovery(number: $0.slot, at: $0.at) },
                    // swapd knows nothing about this Mac's Claude Code
                    // sessions, and its list is not `AccountList` bytes the
                    // phone could decode — both stay nil, like the proxy's.
                    liveSessions: nil, raw: nil)
    }

    /// swapd's kebab-case statuses in cswap's vocabulary — the one every
    /// surface already renders (`SentinelNotes`, `TeamFleetDoc`).
    /// `stale` is not a sentinel: the windows are simply an older good
    /// fetch, which the row shows as usage with its age beside it.
    public static func usageStatus(_ raw: String) -> String {
        switch raw {
        case "ok", "stale": return "ok"
        case "relogin-required": return "relogin_required"
        case "token-expired": return "token_expired"
        case "no-credentials": return "no_credentials"
        case "api-key": return "api_key"
        default: return raw.replacingOccurrences(of: "-", with: "_")
        }
    }

    public static func account(_ view: SwapdAccountView, now: Date = Date()) -> Account {
        let status = usageStatus(view.usageStatus)
        // What the row DISPLAYS. `stale` is not a sentinel — it has no
        // note to show instead — so it shows numbers, and the engine as
        // landed empties `windows` and moves the measurement into
        // `lastGood` for every non-`ok` status (collect.rs `account_view`:
        // "one shape per status"), which would otherwise leave the row
        // both noteless and dataless. A sentinel keeps `usage` nil: its
        // note IS the row, the way cswap's sentinel rows read.
        let shown = view.windows.isEmpty && view.usageStatus == "stale"
            ? (view.lastGood?.windows ?? []) : view.windows
        return Account(number: view.slot, email: view.email,
                       organizationName: view.organizationName,
                       organizationUuid: view.organizationUuid,
                       // swapd reports no org/personal flag and nothing in
                       // the app reads one (the proxy's rows say false too).
                       isOrganization: false,
                       active: view.active,
                       usageStatus: status,
                       usage: usage(shown, now: now),
                       // The engine's own list, in its report order. A
                       // `UsageWindow` has no `kind`, so a window without a
                       // name of its own wears its kind as one — otherwise
                       // 5h, 7d and monthly would be indistinguishable
                       // here. Same source as `usage`, so the raw list and
                       // the derived view can never disagree.
                       windows: shown.isEmpty ? nil
                           : shown.map { window($0, now: now, fallbackName: $0.kind) },
                       alias: view.alias, icon: view.icon, plan: view.plan,
                       disabled: view.disabled, preferred: view.preferred,
                       // A served measurement carries the age of the fetch
                       // it came from, not of the pass that served it.
                       usageFetchedAt: view.fetchedAt ?? view.lastGood?.fetchedAt,
                       usageAgeSeconds: view.ageSeconds ?? view.lastGood?.ageSeconds,
                       lastGoodUsage: view.lastGood.map { usage($0.windows, now: now) } ?? nil,
                       lastGoodFetchedAt: view.lastGood?.fetchedAt,
                       lastGoodAgeSeconds: view.lastGood?.ageSeconds)
    }

    /// The contract's window list as today's UI (and the phone's decoder)
    /// reads usage: 5h, 7d, the scoped gauges, one spend pool.
    public static func usage(_ windows: [SwapdWindow], now: Date = Date()) -> Usage? {
        var fiveHour: UsageWindow?, sevenDay: UsageWindow?
        var scoped: [UsageWindow] = []
        var spend: Spend?
        for w in windows {
            switch w.kind {
            case "5h": fiveHour = window(w, now: now)
            case "7d": sevenDay = window(w, now: now)
            case "scoped": scoped.append(window(w, now: now))
            case "spend":
                // A spend pool without the money has nothing to render —
                // dropped rather than shown as a zero-dollar gauge.
                guard let used = w.used, let limit = w.limit, let currency = w.currency
                else { continue }
                let (countdown, clock) = reset(w.resetsAt, now: now)
                spend = Spend(used: used, limit: limit, pct: w.pct, currency: currency,
                              resetsAt: w.resetsAt, countdown: countdown, clock: clock)
            default:
                // daily / monthly / a kind this build predates: its own
                // named gauge beside the scoped ones, never dropped.
                scoped.append(window(w, now: now, fallbackName: w.kind))
            }
        }
        if fiveHour == nil, sevenDay == nil, scoped.isEmpty, spend == nil { return nil }
        return Usage(fiveHour: fiveHour, sevenDay: sevenDay,
                     scoped: scoped.isEmpty ? nil : scoped, spend: spend)
    }

    static func window(_ w: SwapdWindow, now: Date, fallbackName: String? = nil) -> UsageWindow {
        let (countdown, clock) = reset(w.resetsAt, now: now)
        return UsageWindow(pct: w.pct, resetsAt: w.resetsAt, countdown: countdown, clock: clock,
                           name: w.name ?? fallbackName,
                           expectedPct: w.pace?.expectedPct, aheadOfPace: w.pace?.ahead,
                           projectedExhaustionAt: w.pace?.exhaustsAt,
                           willLastToReset: w.pace?.lastsToReset)
    }

    /// Countdown + wall clock for a reset instant — the app's job, over the
    /// same `ResetFormat` port every other engine's rows use.
    static func reset(_ iso: String?, now: Date) -> (String?, String?) {
        guard let date = WeeklyRoll.parse(iso) else { return (nil, nil) }
        return (ResetFormat.countdown(until: date, now: now), ResetFormat.clock(date, now: now))
    }
}
