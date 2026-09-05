import XCTest
@testable import InfinitusCore

/// `NineRouterFleet` — the cache and engine-SELECTION layer the Windows
/// tray, the Windows daemon's `/snapshot` and (via the same routing
/// check) the Mac's AppModel all reason about.
///
/// The network side is `NineRouterEngineTests`; what is pinned here is
/// the policy, because getting it wrong is invisible until a user is
/// swapping a credential nobody uses: 9Router routed but cswap installed
/// used to leave the panel on cswap's flattened list.
final class NineRouterFleetTests: XCTestCase {
    /// Any one of routed / configured / locally-authenticated is enough
    /// to make 9Router a candidate — the env pin (used by the daemon's
    /// tests, `INFINITUS_CSWAP=""`) overrides all three.
    func testAvailabilityTakesAnyOfTheThreeSignals() {
        typealias S = NineRouterFleet.Selection
        XCTAssertTrue(S.isAvailable(routed: true, configured: false, locallyAuthenticated: false))
        XCTAssertTrue(S.isAvailable(routed: false, configured: true, locallyAuthenticated: false))
        XCTAssertTrue(S.isAvailable(routed: false, configured: false, locallyAuthenticated: true))
        XCTAssertFalse(S.isAvailable(routed: false, configured: false, locallyAuthenticated: false))
        XCTAssertFalse(S.isAvailable(routed: true, configured: true, locallyAuthenticated: true,
                                     pinnedOff: true),
                       "the env pin must win, or a test box's real router leaks into fixtures")
    }

    /// Claude Code's own `env.ANTHROPIC_BASE_URL` decides who is primary
    /// — the Mac's rule (AppModel sets `routedVia9Router` off exactly
    /// this and hands `EngineRegistry.routedEngineID` to 9Router).
    func testRoutingDecidesThePrimaryEngine() {
        typealias S = NineRouterFleet.Selection
        // Routed: 9Router holds the traffic even with cswap installed.
        XCTAssertTrue(S.shouldUseNineRouter(available: true, routed: true, cswapInstalled: true))
        // Not routed but no cswap: 9Router is the only engine there is.
        XCTAssertTrue(S.shouldUseNineRouter(available: true, routed: false, cswapInstalled: false))
        // Not routed and cswap installed: cswap keeps the fleet.
        XCTAssertFalse(S.shouldUseNineRouter(available: true, routed: false, cswapInstalled: true))
        // Unavailable is never primary, whatever else is true.
        XCTAssertFalse(S.shouldUseNineRouter(available: false, routed: true, cswapInstalled: false))
    }

    /// The config file lives per-platform ($APPDATA on Windows, App
    /// Support on the Mac) but is the same JSON, so a Settings window on
    /// either side writes something the other's engine can read.
    func testStoredConfigRoundTripsAndLivesUnderInfinitus() throws {
        let stored = NineRouterFleet.StoredConfig(baseURL: "http://127.0.0.1:20128", password: "pw")
        let data = try JSONEncoder().encode(stored)
        let back = try JSONDecoder().decode(NineRouterFleet.StoredConfig.self, from: data)
        XCTAssertEqual(back.baseURL, "http://127.0.0.1:20128")
        XCTAssertEqual(back.password, "pw")
        XCTAssertEqual(NineRouterFleet.configURL.lastPathComponent, "9router.json")
        XCTAssertEqual(NineRouterFleet.configURL.deletingLastPathComponent().lastPathComponent,
                       "Infinitus")
    }

    /// A refusal is reported in the engine's own words, never as a
    /// cheerful "switched" (CLAUDE.md: the engine owns account policy;
    /// the app forwards a click and reports the answer).
    func testSwitchOutcomeMessagesAreTheEnginesOwn() {
        XCTAssertEqual(NineRouterFleet.SwitchOutcome.switched(to: 3).message,
                       "switched to account 3")
        XCTAssertEqual(NineRouterFleet.SwitchOutcome.noEngine.message,
                       "no swap engine installed")
        XCTAssertEqual(NineRouterFleet.SwitchOutcome.failed(detail: "cooling down").message,
                       "cooling down")
        XCTAssertEqual(NineRouterFleet.SwitchOutcome.failed(detail: "").message,
                       "engine refused the switch", "a silent refusal still says something")
    }

    /// The synchronous reads must never block their caller: the Windows
    /// tray calls them on its 5 s tick and the account panel on every
    /// paint, and a 20 s engine timeout on the UI thread would freeze the
    /// whole tray. `wait: false` (the default) hands the fetch to a
    /// detached thread and answers from the cache immediately — true
    /// whether or not this box actually runs 9Router.
    func testCachedReadsReturnImmediately() {
        let start = Date()
        _ = NineRouterFleet.fleets()
        _ = NineRouterFleet.list()
        NineRouterFleet.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                          "a cached read must not wait on the engine")
    }
}
