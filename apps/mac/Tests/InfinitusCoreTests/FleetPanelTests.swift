import XCTest
@testable import InfinitusCore

/// The shared fleet PRESENTATION (Sources/InfinitusCore/FleetPanel.swift).
///
/// This is the seam that stopped the Windows account panel from being a
/// second implementation: before it, Windows built its rows from one
/// flattened `cswap list --json` and so had no 9Router fleets, no
/// provider headers and no engine indicator, while the Mac's `FleetStack`
/// stacked one section per `EngineFleet`. Both now read these functions,
/// so a disagreement about the same account fails HERE rather than
/// showing up as two different numbers on two machines.
///
/// Runs on every platform (`swift test` on macOS, Linux and Windows) —
/// InfinitusCore imports no UI toolkit, which is the whole point.
final class FleetPanelTests: XCTestCase {
    private func account(_ n: Int, _ email: String, usage: Usage? = nil,
                         active: Bool = false, alias: String? = nil,
                         disabled: Bool? = nil) -> Account {
        Account(number: n, email: email, active: active, usage: usage,
                alias: alias, disabled: disabled)
    }

    private func fleets() -> [EngineFleet] {
        [
            EngineFleet(engineID: "9router", provider: .claude, accounts: [
                account(1, "one@example.com",
                        usage: Usage(fiveHour: UsageWindow(pct: 40),
                                     sevenDay: UsageWindow(pct: 10)),
                        active: true, alias: "work"),
                account(2, "two@example.com",
                        usage: Usage(fiveHour: UsageWindow(pct: 100),
                                     sevenDay: UsageWindow(pct: 12))),
            ], activeNumber: 1),
            EngineFleet(engineID: "9router", provider: .gemini, accounts: [
                account(1, "g@example.com",
                        usage: Usage(scoped: [UsageWindow(pct: 30, name: "Gemini 3.8 Flash")])),
            ], activeNumber: 1),
            EngineFleet(engineID: "9router", provider: .codex, accounts: [
                account(1, "c@example.com"),
            ], activeNumber: 1),
        ]
    }

    /// The header line the Mac composes out of styled `Text`s and the
    /// Win32 panel draws as one string — same words, same order.
    func testFleetLabelReadsProviderThenEngine() {
        XCTAssertEqual(FleetLabel(engineName: "9Router", provider: .claude).text,
                       "Claude \u{00B7} 9Router")
        XCTAssertEqual(FleetLabel(engineName: "9Router", provider: .gemini).text,
                       "Gemini \u{00B7} 9Router")
        XCTAssertEqual(
            FleetLabel(engineName: "CLIProxyAPI", provider: .claude,
                       caveat: "round-robin ignores priority tiers").text,
            "Claude \u{00B7} CLIProxyAPI \u{2014} round-robin ignores priority tiers")
    }

    /// One table for engine names, so the Mac popup, the phone's mirror
    /// and the Windows panel can't drift into three spellings.
    func testEngineCatalogNamesEveryEngineTheHostsMirror() {
        XCTAssertEqual(EngineCatalog.displayName(for: "cswap"), "cswap")
        XCTAssertEqual(EngineCatalog.displayName(for: "cliproxy"), "CLIProxyAPI")
        XCTAssertEqual(EngineCatalog.displayName(for: "9router"), "9Router")
        XCTAssertEqual(EngineCatalog.displayName(for: "claude-code-windows"), "Claude Code")
        XCTAssertEqual(EngineCatalog.displayName(for: "claude-code-windows-9router"), "9Router")
        // An engine this build doesn't know still names itself, rather
        // than rendering an empty header.
        XCTAssertEqual(EngineCatalog.displayName(for: "future"), "future")
    }

    /// Several fleets stack, one section each, in the order the engine
    /// reported them — that is what 9Router's Claude/Gemini/Codex
    /// providers become on both frontends.
    func testEveryFleetBecomesItsOwnSection() {
        let panel = FleetPanel.panel(fleets: fleets(), live: nil, engineInstalled: true)
        XCTAssertNil(panel.empty)
        XCTAssertEqual(panel.sections.map(\.key),
                       ["9router/claude", "9router/gemini", "9router/codex"])
        XCTAssertEqual(panel.sections.map(\.label.text),
                       ["Claude \u{00B7} 9Router", "Gemini \u{00B7} 9Router", "Codex \u{00B7} 9Router"])
        XCTAssertEqual(panel.rows.count, 4)
        XCTAssertEqual(panel.activeNumber, 1)
    }

    /// Headers appear only when several fleets have rows — a one-fleet
    /// panel is byte-identical to the pre-multi-fleet one, which is the
    /// Mac's `FleetStack` rule ("with one fleet nothing is added").
    func testHeadersOnlyWhenSeveralFleetsHaveRows() {
        let many = FleetPanel.panel(fleets: fleets(), live: nil, engineInstalled: true)
        let headers = many.lines.compactMap { line -> FleetLabel? in
            if case .header(let l) = line { return l }
            return nil
        }
        XCTAssertEqual(headers.count, 3)
        // Header, then that fleet's rows, then the next header.
        guard case .header = many.lines.first else { return XCTFail("expected a header first") }
        guard case .account = many.lines[1] else { return XCTFail("expected a row after the header") }

        let one = FleetPanel.panel(fleets: [fleets()[0]], live: nil, engineInstalled: true)
        XCTAssertTrue(one.lines.allSatisfy { if case .account = $0 { return true } else { return false } },
                      "a lone fleet gets no header, exactly like the Mac popup")
        XCTAssertEqual(one.rows.count, 2)

        // An empty fleet alongside a populated one must not earn a
        // header for a section with nothing under it.
        let withEmpty = FleetPanel.panel(
            fleets: [fleets()[0],
                     EngineFleet(engineID: "9router", provider: .kiro, accounts: [])],
            live: nil, engineInstalled: true)
        XCTAssertTrue(withEmpty.lines.allSatisfy {
            if case .account = $0 { return true } else { return false }
        }, "one populated fleet is still a lone fleet")

        // Two populated fleets plus an empty one: the empty section
        // paints nothing, not even a header.
        let mixed = FleetPanel.panel(
            fleets: [fleets()[0],
                     EngineFleet(engineID: "9router", provider: .kiro, accounts: []),
                     fleets()[2]],
            live: nil, engineInstalled: true)
        let mixedHeaders = mixed.lines.compactMap { line -> FleetLabel? in
            if case .header(let l) = line { return l }
            return nil
        }
        XCTAssertEqual(mixedHeaders.count, 2, "the empty section stays headerless")
        guard case .account = mixed.lines.last else { return XCTFail("no trailing header either") }
    }

    /// The "primary" active account is the Claude fleet's even when a
    /// non-Claude fleet stacks first.
    func testActiveNumberPrefersTheClaudeFleet() {
        let reordered = FleetPanel.panel(fleets: [fleets()[1], fleets()[0]], live: nil,
                                         engineInstalled: true)
        XCTAssertEqual(reordered.sections.first?.label.provider, .gemini)
        XCTAssertEqual(reordered.activeNumber, fleets()[0].activeNumber,
                       "the Claude section answers, not whichever is first")
        // Empty Claude alongside a populated Gemini: the empty Claude
        // cannot answer — `lines` already hides it, so the highlight
        // has to come from a section that actually paints.
        let emptyClaude = EngineFleet(engineID: "9router", provider: .claude, accounts: [])
        let geminiOnly = FleetPanel.panel(fleets: [emptyClaude, fleets()[1]], live: nil,
                                          engineInstalled: true)
        XCTAssertTrue(geminiOnly.sections.contains { $0.label.provider == .claude && $0.rows.isEmpty })
        XCTAssertEqual(geminiOnly.activeNumber, fleets()[1].activeNumber)
    }

    /// Every row carries the fleet it came from, because 9Router's
    /// ordinals are PER PROVIDER: forwarding a Gemini row's #1 as a
    /// Claude switch would swap the wrong account.
    func testRowsCarryTheirEngineAndProvider() {
        let panel = FleetPanel.panel(fleets: fleets(), live: nil, engineInstalled: true)
        let gemini = panel.sections[1].rows[0]
        XCTAssertEqual(gemini.engineID, "9router")
        XCTAssertEqual(gemini.provider, .gemini)
        XCTAssertEqual(gemini.number, 1)
        let claude = panel.sections[0].rows[0]
        XCTAssertEqual(claude.provider, .claude)
        XCTAssertEqual(claude.number, 1, "same ordinal, different fleet")
    }

    /// Row naming, death and gauges are the Mac's: alias over local part,
    /// any spent window kills the row, bars fill by REMAINING.
    func testRowNamingDeathAndGaugesMatchTheMac() {
        let panel = FleetPanel.panel(fleets: fleets(), live: nil, engineInstalled: true)
        let rows = panel.sections[0].rows
        XCTAssertEqual(rows[0].name, "work", "alias wins")
        XCTAssertEqual(rows[1].name, "two", "else the address's local part")
        XCTAssertTrue(rows[0].active)
        XCTAssertFalse(rows[0].dead)
        XCTAssertTrue(rows[1].dead)
        XCTAssertEqual(rows[1].deadNote, "5h spent")
        XCTAssertEqual(rows[0].gauges.map(\.label), ["5h", "7d"])
        XCTAssertEqual(rows[0].gauges[0].remaining, 60, "HP semantics: fill is what's LEFT")
        XCTAssertTrue(rows[1].gauges[0].spent)
        // A provider with only per-model windows still gets a gauge, and
        // it is named after the model (Gemini/Antigravity via 9Router).
        XCTAssertEqual(panel.sections[1].rows[0].gauges.map(\.label), ["Gemini 3.8 Flash"])
        // No usage at all draws no bars rather than a row of zeros.
        XCTAssertTrue(panel.sections[2].rows[0].gauges.isEmpty)
    }

    /// The empty states are copy, not errors: no engine says how to get
    /// one (the host supplies its own install hint), no fleets yet says
    /// it is still reading, an engine with zero accounts says how to
    /// register one — without naming any engine.
    func testEmptyStatesDistinguishNoEngineFromNoAccounts() {
        let none = FleetPanel.panel(fleets: [], live: nil, engineInstalled: false)
        XCTAssertEqual(none.empty, "No account engine installed.")
        XCTAssertFalse(none.empty?.contains("cswap") == true, "core copy names no engine")
        let hinted = FleetPanel.panel(fleets: [], live: nil, engineInstalled: false,
                                      installHint: "`pip install claude-swap` adds one.")
        XCTAssertEqual(hinted.empty, "No account engine installed. `pip install claude-swap` adds one.")
        XCTAssertTrue(none.sections.isEmpty)

        let reading = FleetPanel.panel(fleets: [], live: nil, engineInstalled: true)
        XCTAssertEqual(reading.empty, "Reading accounts\u{2026}")

        let bare = FleetPanel.panel(
            fleets: [EngineFleet(engineID: "cswap", provider: .claude, accounts: [])],
            live: nil, engineInstalled: true)
        XCTAssertTrue(bare.empty?.contains("register the account you are logged into") == true)
        XCTAssertFalse(bare.empty?.contains("cswap") == true, "core copy names no engine")
    }

    /// The footer counts sessions and accounts and names the engine —
    /// the 9Router indicator the panel was missing entirely.
    func testFooterCountsAndNamesTheEngine() {
        let live = LiveSessions(busy: 1, total: 3, idle: 1, waiting: 1, shell: 0, unknown: 0, sessions: nil)
        let panel = FleetPanel.panel(
            fleets: fleets(), live: live, engineInstalled: true,
            engine: FleetPanel.EngineIndicator(name: "9Router", routed: true))
        XCTAssertEqual(panel.footer,
                       "3 sessions \u{00B7} 1 busy \u{00B7} 1 waiting \u{00B7} 4 accounts \u{00B7} 9Router \u{00B7} routed")
        XCTAssertEqual(panel.engine?.routed, true)
        // Not routed: the engine is named without claiming the traffic.
        XCTAssertEqual(FleetPanel.EngineIndicator(name: "cswap", routed: false).text, "cswap")
        XCTAssertEqual(FleetPanel.footer(live: nil, accounts: 0), "no sessions")
    }

    /// A caveat rides its engine's header, keyed by engine id — the same
    /// `AppModel.fleetCaveats` lookup `FleetState.fleetLabel` does.
    func testCaveatsAttachToTheirEnginesHeader() {
        let panel = FleetPanel.panel(fleets: fleets(), live: nil, engineInstalled: true,
                                     caveats: ["9router": "priority is 9Router's"])
        XCTAssertEqual(panel.sections[0].label.caveat, "priority is 9Router's")
        XCTAssertTrue(panel.sections[0].label.text.hasSuffix("\u{2014} priority is 9Router's"))
    }

    /// The single-`AccountList` path (a fixture, an older mirror) still
    /// works and produces exactly the one-fleet panel.
    func testAccountListPathIsTheOneFleetPanel() {
        let list = AccountList(activeAccountNumber: 2, accounts: [
            account(1, "a@example.com"),
            account(2, "b@example.com", usage: Usage(fiveHour: UsageWindow(pct: 5))),
        ])
        let panel = FleetPanel.panel(list: list, live: nil, engineInstalled: true)
        XCTAssertEqual(panel.sections.count, 1)
        XCTAssertEqual(panel.sections[0].key, "cswap/claude")
        XCTAssertEqual(panel.activeNumber, 2)
        XCTAssertTrue(panel.rows[1].active, "activeAccountNumber marks the row")
        XCTAssertTrue(panel.lines.allSatisfy {
            if case .account = $0 { return true } else { return false }
        })
        XCTAssertEqual(FleetPanel.panel(list: nil, live: nil, engineInstalled: true).empty,
                       "Reading accounts\u{2026}", "a nil list is still reading, not empty")
    }

    /// The weekly window rolls at its reset instant, and the panel shows
    /// the rolled value — the same `WeeklyRoll` the Mac's grid uses, so
    /// a stale engine percentage can't survive on one platform only.
    func testWeeklyWindowRollsOverInTheGauge() {
        let usage = Usage(fiveHour: UsageWindow(pct: 10),
                          sevenDay: UsageWindow(pct: 88, resetsAt: "2026-09-04T12:00:00Z"))
        let fleet = EngineFleet(engineID: "cswap", provider: .claude,
                                accounts: [account(1, "a@example.com", usage: usage)])
        let before = FleetPanel.panel(fleets: [fleet], live: nil, engineInstalled: true,
                                      now: WeeklyRoll.parse("2026-09-04T11:00:00Z")!)
        XCTAssertEqual(before.rows[0].gauges[1].usedPct, 88, accuracy: 0.001)
        let after = FleetPanel.panel(fleets: [fleet], live: nil, engineInstalled: true,
                                     now: WeeklyRoll.parse("2026-09-04T13:00:00Z")!)
        XCTAssertEqual(after.rows[0].gauges[1].usedPct, 0, accuracy: 0.001,
                       "a rolled weekly window reads as fresh, not 88%")
    }

    /// Which fleet the chrome, the title and `listJSON` follow. Claude
    /// wins wherever it is in the list — the Mac's `EngineRegistry`
    /// ranks Claude first for exactly this reason.
    func testPrimaryFleetIsTheClaudeOne() {
        let all = fleets()
        XCTAssertEqual(EngineFleet.primary(of: all)?.provider, .claude)
        // Claude second: still the primary.
        XCTAssertEqual(EngineFleet.primary(of: [all[1], all[0]])?.provider, .claude)
        // No Claude at all: the first fleet, rather than nothing.
        XCTAssertEqual(EngineFleet.primary(of: [all[1], all[2]])?.provider, .gemini)
        XCTAssertNil(EngineFleet.primary(of: []))
    }

    /// `listJSON` for a phone older than `fleets`: the primary fleet as an
    /// `AccountList`, with the host's own session counts when it has them.
    func testPrimaryListFlattensForOlderClients() throws {
        let live = LiveSessions(busy: 2, total: 5, idle: 3, waiting: 0, shell: 0, unknown: 0, sessions: nil)
        let list = try XCTUnwrap(EngineFleet.primaryList(fleets(), liveSessions: live))
        XCTAssertEqual(list.schemaVersion, 1)
        XCTAssertEqual(list.activeAccountNumber, 1)
        XCTAssertEqual(list.accounts.map(\.email), ["one@example.com", "two@example.com"])
        XCTAssertEqual(list.liveSessions?.total, 5)
        // Without an override the fleet's own sessions ride along.
        let fleetSessions = LiveSessions(busy: 0, total: 1, idle: 1, waiting: 0, shell: 0,
                                         unknown: 0, sessions: nil)
        let own = EngineFleet(engineID: "cswap", provider: .claude, accounts: [],
                              liveSessions: fleetSessions)
        XCTAssertEqual(EngineFleet.primaryList([own])?.liveSessions?.total, 1)
        XCTAssertNil(EngineFleet.primaryList([]))
    }
}
