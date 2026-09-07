import Foundation

/// The transcript → `SessionTimeline` walk (#223 phase 1). A second pass
/// over the entries `SessionFeedReader.read` already decodes; the legacy
/// `parse` is untouched. Mirrors T3's ProviderRuntimeIngestion +
/// projector rules with the transcript as the source instead of the SDK.
public enum SessionTimelineBuilder {
    public static func build(entries: [[String: Any]], status: String?, statusUpdatedAt: Date? = nil,
                             agents: [String: SessionFeedItem.Agent] = [:], now: Date = Date()) -> SessionTimeline {
        SessionTimeline()
    }
}
