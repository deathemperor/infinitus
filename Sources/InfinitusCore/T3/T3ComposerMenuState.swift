import Foundation

/// The keys an open menu claims before the field does
/// (`onComposerCommandKey`, `ChatComposer.tsx:3080-3125`): ↑/↓ move the
/// highlight, ⏎ and ⇥ pick it, ⎋ shuts the menu (ours — see
/// `T3ComposerMenuState`).
public enum T3ComposerMenuKey: Sendable {
    case up, down, pick, dismiss
}

/// The `/` and `@` menu's own state, apart from the view: which row is
/// highlighted and under which query, and which trigger ⎋ shut. The
/// trigger itself is derived from the text and caret on every read
/// (`T3ComposerTrigger.detect`); this decides what it means.
public struct T3ComposerMenuState: Equatable, Sendable {
    /// `composerMenuHighlight.ts`: the row the user moved to, and the
    /// `searchKey` it was moved under (a changed query resets it).
    public var highlighted: String?
    public var highlightedKey: String?
    /// `dismissKey` of the trigger ⎋ shut — typing on inside that trigger
    /// keeps it shut, a fresh `/` (or an `@` at another offset) opens again.
    public var dismissed: String?

    public init() {}

    /// Which trigger occurrence ⎋ shuts: its kind and start, not its query —
    /// typing on inside a dismissed trigger keeps it shut, while a fresh `/`
    /// (or an `@` at another offset) opens a menu again.
    public static func dismissKey(_ found: T3ComposerTrigger.Detected) -> String {
        "\(found.kind.rawValue):\(found.start)"
    }

    /// The trigger the menu shows for the raw detection: nil when ⎋ shut it.
    public func trigger(_ raw: T3ComposerTrigger.Detected?) -> T3ComposerTrigger.Detected? {
        guard let found = raw else { return nil }
        return Self.dismissKey(found) == dismissed ? nil : found
    }

    /// The raw detection moved (the view's `.onChange`): a dismissal outlives
    /// only its own trigger — the moment the caret is on another one (or on
    /// none) it lapses.
    public mutating func triggerMoved(_ raw: T3ComposerTrigger.Detected?) {
        let key = raw.map(Self.dismissKey)
        if key != dismissed { dismissed = nil }
    }

    /// A menu opened (or closed): the highlight starts over.
    public mutating func opened() {
        highlighted = nil
        highlightedKey = nil
    }

    /// `resolveComposerMenuActiveItemId` (`composerMenuHighlight.ts`).
    public func activeItemID(_ itemIDs: [String], trigger: T3ComposerTrigger.Detected) -> String? {
        T3ComposerMenuHighlight.resolve(itemIDs: itemIDs, highlighted: highlighted,
                                        currentKey: trigger.searchKey, highlightedKey: highlightedKey)
    }

    /// A row hovered/pointed at.
    public mutating func highlight(_ id: String, trigger: T3ComposerTrigger.Detected) {
        highlighted = id
        highlightedKey = trigger.searchKey
    }

    public enum KeyOutcome: Equatable, Sendable {
        case moved            // ↑/↓ moved the highlight
        case pick(String)     // ⏎/⇥ chose this item id — the view inserts it
        case dismissed        // ⎋ shut the menu
        case unhandled        // the field keeps the key
    }

    /// `onComposerCommandKey` (`ChatComposer.tsx:3080-3125`): while a menu is
    /// open it takes ↑/↓ and ⏎/⇥ first. `trigger` nil (no menu) → `.unhandled`
    /// for every key; ↑/↓ with no rows → `.unhandled`; `.pick` with no active
    /// row → `.unhandled` (⏎ then sends the prompt, as upstream).
    public mutating func key(_ key: T3ComposerMenuKey, trigger: T3ComposerTrigger.Detected?,
                             itemIDs: [String]) -> KeyOutcome {
        guard let trigger else { return .unhandled }
        switch key {
        case .up, .down:
            // Upstream nudges from the STORED highlight, which its sync
            // effect (`:2298-2320`) has already set to the resolved active
            // row; this port resolves on read instead, so the nudge starts
            // there.
            guard !itemIDs.isEmpty else { return .unhandled }
            highlighted = T3ComposerMenuHighlight.nudge(itemIDs: itemIDs,
                                                        highlighted: activeItemID(itemIDs, trigger: trigger),
                                                        direction: key == .down ? 1 : -1)
            highlightedKey = trigger.searchKey
            return .moved
        case .pick:
            // `(key === "Enter" || key === "Tab") && selectedItem` (`:3104`):
            // with nothing to pick, ⏎ sends the prompt as upstream does.
            guard let active = activeItemID(itemIDs, trigger: trigger) else { return .unhandled }
            return .pick(active)
        case .dismiss:
            dismissed = Self.dismissKey(trigger)
            return .dismissed
        }
    }

    /// A row was inserted: the menu's state is spent, dismissal included.
    public mutating func picked() {
        highlighted = nil
        highlightedKey = nil
        dismissed = nil
    }
}
