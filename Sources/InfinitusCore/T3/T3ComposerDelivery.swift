import Foundation

/// One delivery into the composer's inbox (`T3ComposerInbox`): a kind of
/// content plus a sequence number. `.onChange` diffs the whole value, so
/// without a sequence number two deliveries of the same kind in a row (two
/// sidebar drops onto the same thread, back to back) would look unchanged
/// and never fire a second time — the seq is what makes every `send` a
/// fresh event, payload aside.
public struct T3ComposerDelivery: Equatable, Sendable {
    /// What landed: the plan card's Refine text (Task 12), the Files tab's
    /// "Add to chat" mention (B-32), or a sidebar drop's signal — the
    /// drop's own files stay queued on `T3WindowModel.pendingFileDrops`
    /// keyed by thread, so this case carries no payload of its own.
    public enum Kind: Equatable, Sendable {
        case insert(String)
        case mention(String)
        case fileDrop
    }

    public let kind: Kind
    public let seq: Int

    public init(kind: Kind, seq: Int) {
        self.kind = kind
        self.seq = seq
    }

    /// Builds the next delivery after `lastSeq` — the inbox's own running
    /// counter, not the slot's last value: the slot is emptied the moment
    /// the composer takes it, so nothing survives there to count from.
    public static func next(_ kind: Kind, after lastSeq: Int) -> T3ComposerDelivery {
        T3ComposerDelivery(kind: kind, seq: lastSeq + 1)
    }

    /// The take-once rule every slot in this file follows: read whatever is
    /// there, then empty it, so a second take sees nothing.
    public static func take(_ slot: inout T3ComposerDelivery?) -> Kind? {
        defer { slot = nil }
        return slot?.kind
    }
}
