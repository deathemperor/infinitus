import Foundation
import InfinitusCore

/// The live forecast, plan and token rate for readers that don't hold
/// the AppModel (the Utilization pane did, until it left with #654; the
/// `utilization` control verb reads it now). AppModel publishes here
/// every snapshot. One writer, read on the main actor only.
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
