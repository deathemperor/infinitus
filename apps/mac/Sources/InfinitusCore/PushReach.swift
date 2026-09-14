import Foundation

/// What a `push` actually addressed: the phones a request went out to,
/// by device and by token kind. `{pushed: true}` alone read as success
/// when no phone held a registration and nothing was sent (a synthetic
/// `thread.activity` push "succeeded" into nothing); the reply now
/// carries `targets` (distinct phones) and `kinds` (requests per token
/// kind: `alert`, `agent-activity`, `agent-activity-start`), both zero
/// when nobody is registered or the pusher is not configured.
public struct PushReach: Equatable, Sendable {
    public private(set) var kinds: [String: Int] = [:]
    private var devices: Set<String> = []

    public init() {}

    /// Distinct phones at least one request went out to.
    public var targets: Int { devices.count }

    public mutating func add(device: String, kind: String) {
        devices.insert(device)
        kinds[kind, default: 0] += 1
    }

    /// The two reply fields, to merge into a verb's result object.
    public var replyFields: [String: JSONValue] {
        ["targets": .number(Double(targets)),
         "kinds": .object(kinds.mapValues { .number(Double($0)) })]
    }
}
