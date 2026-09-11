import Foundation

/// One account verb from the phone, `POST /accounts/action`: star,
/// unstar, pause or resume an account of the PRIMARY Mac's fleet. The
/// verbs are the control protocol's own (`prefer … on|off`, `hold`,
/// `unhold`) so the CLI and the phone speak the same words; the Mac
/// runs the same capability guards and lands on a starred account
/// the way the popup does.
public enum AccountAction {
    public static let path = "/accounts/action"

    public struct Request: Codable, Sendable, Equatable {
        /// The fleet's registry key, `engineID/provider` (EngineFleet.key).
        public let fleet: String
        public let number: Int
        /// `prefer` / `unprefer` flip the engine's pick-first knob;
        /// `hold` / `unhold` take the account out of rotation and back.
        public let action: String

        public init(fleet: String, number: Int, action: String) {
            self.fleet = fleet
            self.number = number
            self.action = action
        }
    }

    public struct Reply: Codable, Sendable, Equatable {
        /// "done" | "unsupported" | "notFound" | "failed"
        public let outcome: String
        public let detail: String?

        public init(outcome: String, detail: String? = nil) {
            self.outcome = outcome
            self.detail = detail
        }
    }
}
