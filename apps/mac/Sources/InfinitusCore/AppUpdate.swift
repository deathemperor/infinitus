import Foundation

/// The control socket's `app-update` verb (#121; once the phone's `POST
/// /app/update` on the mirror, retired with #1041) — the Mac decides from its own `AppReleaseModel`/`BrewUpdater` state, same as
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
