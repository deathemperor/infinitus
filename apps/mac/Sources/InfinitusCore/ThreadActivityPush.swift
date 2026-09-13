import Foundation

/// The phone's lock-screen thread card (#1047): the desktop folds its
/// threads' phases into the state upstream's `AgentActivity` widget
/// draws — `{title, subtitle, activeCount, updatedAt, activities: [...]}`
/// — and hands it to the `push` verb as `{kind: "thread.activity",
/// state}`; `state: null` ends the card. The Mac never reads the rows:
/// the object travels whole into the expo-widgets envelope's `props`.
public struct AgentActivityState: Equatable, Sendable {
    /// The card's headline, also the push-to-start alert's title.
    public let title: String
    /// The line under it, also the push-to-start alert's body.
    public let subtitle: String
    /// The whole state as JSON with sorted keys, so two equal states are
    /// the same string (the pusher skips a repeat).
    public let props: String

    public init(title: String, subtitle: String, props: String) {
        self.title = title
        self.subtitle = subtitle
        self.props = props
    }

    /// The widget's props shape, checked at the door: a stray object is
    /// refused rather than pushed to a phone that cannot draw it.
    public static func parse(_ object: [String: Any]) -> AgentActivityState? {
        guard let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let subtitle = object["subtitle"] as? String,
              object["activeCount"] is Int,
              object["updatedAt"] is String,
              object["activities"] is [Any],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return AgentActivityState(title: title, subtitle: subtitle,
                                  props: String(decoding: data, as: UTF8.self))
    }
}

public enum ThreadActivityPush: Equatable, Sendable {
    /// A card to start or redraw.
    case show(AgentActivityState)
    /// Nothing running or waiting: end the card.
    case end

    /// `{kind: "thread.activity", state: {...} | null}`; nil for any
    /// other shape (a `thread.phase` line is the other parser's).
    public static func parse(_ json: String) -> ThreadActivityPush? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              object["kind"] as? String == "thread.activity",
              let stateValue = object["state"] else { return nil }
        if stateValue is NSNull { return .end }
        guard let stateObject = stateValue as? [String: Any],
              let state = AgentActivityState.parse(stateObject) else { return nil }
        return .show(state)
    }
}
