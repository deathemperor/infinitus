import Foundation

/// T3's live-follow latch (`thread-feed-live-follow.ts`
/// `resolveThreadFeedLiveFollow`): the feed follows new rows only while the
/// reader is at the end. Scrolling away or opening a fold above the end
/// breaks follow; reaching the end again, opening the thread or sending
/// re-arms it. Only events inside a user scroll session (drag start
/// through the end of its momentum) can break follow, so programmatic
/// scrolls never strand a follower.
enum T3LiveFollow {
    enum Event: Equatable {
        case reset
        case userScrollBegin
        case userScrollEnd(isAtEnd: Bool, sessionActive: Bool)
        case scroll(isAtEnd: Bool, sessionActive: Bool)
        case disclosureSettled(isAtEnd: Bool, sessionActive: Bool)
    }

    static func resolve(_ current: Bool, _ event: Event) -> Bool {
        switch event {
        case .reset:
            return true
        case .userScrollBegin:
            return false
        case .userScrollEnd(let isAtEnd, let sessionActive):
            return sessionActive ? isAtEnd : current
        case .disclosureSettled(let isAtEnd, let sessionActive):
            return !sessionActive && isAtEnd
        case .scroll(let isAtEnd, let sessionActive):
            if sessionActive { return false }
            if isAtEnd { return true }
            return current
        }
    }
}
