import Foundation

/// T3 Code's read model for one session (#223 phase 1): flat messages and
/// a sidecar activity timeline joined by `turnId`
/// (t3code `packages/contracts/src/orchestration.ts:354-363, :485-536`).
/// Built from the transcript by `SessionTimelineBuilder`; ids are
/// deterministic so two reads of one file are `==`.
public struct SessionTimeline: Codable, Sendable, Equatable {
    public var turns: [Turn]
    public var messages: [Message]
    public var activities: [Activity]

    public init(turns: [Turn] = [], messages: [Message] = [], activities: [Activity] = []) {
        self.turns = turns
        self.messages = messages
        self.activities = activities
    }

    public var latestTurn: Turn? { turns.last }
    public func turn(id: String) -> Turn? { turns.first { $0.id == id } }
    public func message(id: String) -> Message? { messages.first { $0.id == id } }
    public func activity(id: String) -> Activity? { activities.first { $0.id == id } }

    enum CodingKeys: String, CodingKey { case turns, messages, activities }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        activities = try c.decodeIfPresent([Activity].self, forKey: .activities) ?? []
    }
}

public struct Turn: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, interrupted, completed, error }
    public let id: String
    public let state: State
    public let requestedAt: Date
    public let startedAt: Date?
    public let completedAt: Date?
    public let userMessageId: String
    public let assistantMessageId: String?
    public init(id: String, state: State, requestedAt: Date, startedAt: Date?, completedAt: Date?,
                userMessageId: String, assistantMessageId: String?) {
        self.id = id; self.state = state; self.requestedAt = requestedAt
        self.startedAt = startedAt; self.completedAt = completedAt
        self.userMessageId = userMessageId; self.assistantMessageId = assistantMessageId
    }
}

public struct Message: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let id: String
    public let role: Role
    public let text: String
    public let images: [String]?
    public let sender: String?
    public let turnId: String
    public let streaming: Bool
    public let createdAt: Date
    public init(id: String, role: Role, text: String, images: [String]?, sender: String?,
                turnId: String, streaming: Bool, createdAt: Date) {
        self.id = id; self.role = role; self.text = text; self.images = images; self.sender = sender
        self.turnId = turnId; self.streaming = streaming; self.createdAt = createdAt
    }
}

/// `kind` and `payload` are open (strings, JSON) — a new activity ships
/// without a phone release; unknown kinds render as a plain line.
public struct Activity: Codable, Sendable, Equatable {
    public enum Tone: String, Codable, Sendable { case info, tool, approval, error }
    public let id: String
    public let tone: Tone
    public let kind: String
    public let summary: String
    public let detail: String?
    public let payload: [String: JSONValue]
    public let turnId: String
    public let sequence: Int
    public let createdAt: Date
    public init(id: String, tone: Tone, kind: String, summary: String, detail: String?,
                payload: [String: JSONValue], turnId: String, sequence: Int, createdAt: Date) {
        self.id = id; self.tone = tone; self.kind = kind; self.summary = summary; self.detail = detail
        self.payload = payload; self.turnId = turnId; self.sequence = sequence; self.createdAt = createdAt
    }
}
