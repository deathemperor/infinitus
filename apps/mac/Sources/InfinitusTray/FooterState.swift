import Foundation
import InfinitusCore

/// Footer-chip state for one tray invocation (#9 parity): the Anthropic
/// service indicator (TrayServiceStatus, file-cached) and whether a
/// `cswap auto` process is alive (EngineProbe) — computed once and fed
/// both to the panel JSON (QML render) and the fleet mirror export (the
/// phone's footer, once `serve` exists).
struct FooterState {
    let indicator: String   // none | minor | major | critical | unknown
    let engineRunning: Bool

    static func current(now: Date = Date()) async -> FooterState {
        let indicator = await TrayServiceStatus.current(now: now)
        return FooterState(indicator: indicator, engineRunning: EngineProbe.isRunning())
    }

    /// `nil` when unknown — a pre-D2 mac phone drops the chip the same
    /// way it drops a snapshot that never set this field at all.
    var serviceStatus: ServiceStatusSummary? {
        indicator == "unknown" ? nil : ServiceStatusSummary(indicator: indicator)
    }

    var engine: EngineBadge { engineRunning ? .running : .stopped }

    var panelStatus: PanelServiceStatus {
        PanelServiceStatus(indicator: indicator, word: TrayServiceStatus.word(for: indicator))
    }

    var panelEngine: PanelEngine {
        PanelEngine(running: engineRunning, word: engineRunning ? "auto" : "off")
    }
}
