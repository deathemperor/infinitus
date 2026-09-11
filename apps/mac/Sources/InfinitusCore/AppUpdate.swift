import Foundation

/// The phone's trigger for this Mac's own update (#121): `POST
/// /app/update` (path lives on `MirrorTransport`, empty body) — the Mac
/// decides from its own `AppReleaseModel`/`BrewUpdater` state, same as
/// the About pane's button.
public enum AppUpdate {
    public struct Reply: Codable, Sendable, Equatable {
        /// "started" | "unavailable" | "upToDate"
        public let outcome: String
        public let detail: String?
        public init(outcome: String, detail: String? = nil) {
            self.outcome = outcome
            self.detail = detail
        }
    }
}
