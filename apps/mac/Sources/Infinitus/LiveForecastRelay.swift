import Foundation
import InfinitusCore

/// The live forecast, plan and token rate for panes that don't hold the
/// AppModel (UtilizationPane is built with its own model in
/// InfinitusApp.swift). AppModel publishes here every snapshot; the pane
/// observes it. One writer, read on the main actor only.
@MainActor
final class LiveForecastRelay: ObservableObject {
    static let shared = LiveForecastRelay()
    @Published var forecast: UsageForecast?
    @Published var plan: WindowPlanner.Plan?
    @Published var tokenRate: TokenRate?
    /// The popup's row theme, so the dashboard names gauges the same way.
    @Published var theme: RowTheme = .off
    private init() {}
}
