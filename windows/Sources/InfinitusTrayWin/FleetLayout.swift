import Foundation
import InfinitusCore

/// The account panel's CONTENT — now a thin alias over Core's shared
/// `FleetPanel` (Sources/InfinitusCore/FleetPanel.swift).
///
/// Why this file still exists: the Win32 painting code addresses these
/// names, and the seam is where the tray's own engine reads (TrayFleet)
/// meet the shared layout. What it no longer does is DECIDE anything.
/// Every label, row name, death note, gauge and footer string is Core's,
/// the same values the Mac's `FleetStack`/`FleetHeader` render — before
/// this, Windows had a second copy that only ever saw one flattened
/// `cswap list --json` and so had no 9Router fleets, no provider headers
/// and no engine indicator (user 2026-09-05: "account panels show
/// missing: no 9Router info … why not share logic from mac to win").
///
/// The Mac gets its row from ~40 lines of SwiftUI because SwiftUI does
/// the layout; Win32 has no layout engine (the Windows Swift SDK ships
/// no SwiftUI/AppKit/UIKit — verified 2026-09-04, 25 modules), so every
/// rectangle is still computed by hand in FleetWindow.swift. Only the
/// arithmetic of PAINTING is local; the arithmetic of MEANING is shared.
enum FleetLayout {
    typealias Gauge = FleetPanel.Gauge
    typealias Row = FleetPanel.Row
    typealias Section = FleetPanel.Section
    typealias Line = FleetPanel.Line
    typealias Panel = FleetPanel.Panel

    /// Multi-fleet panel: one section per `EngineFleet`, headers when
    /// several stack (the Mac's `FleetStack` rule).
    static func panel(fleets: [EngineFleet], live: LiveSessions?,
                      engineInstalled: Bool,
                      engine: FleetPanel.EngineIndicator? = nil,
                      now: Date = Date()) -> Panel {
        FleetPanel.panel(fleets: fleets, live: live, engineInstalled: engineInstalled,
                         engine: engine, now: now)
    }

    /// Single-fleet panel, for the fixture path and any caller that only
    /// holds a `cswap list --json` payload.
    static func panel(list: AccountList?, live: LiveSessions?,
                      engineInstalled: Bool,
                      engine: FleetPanel.EngineIndicator? = nil,
                      now: Date = Date()) -> Panel {
        FleetPanel.panel(list: list, live: live, engineInstalled: engineInstalled,
                         engine: engine, now: now)
    }

    static func footer(live: LiveSessions?, accounts: Int,
                       engine: FleetPanel.EngineIndicator? = nil) -> String {
        FleetPanel.footer(live: live, accounts: accounts, engine: engine)
    }
}
