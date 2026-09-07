import SwiftUI
import InfinitusCore

/// One item of a session's chat feed, drawn the same on every client
/// (#151): the phone's `SessionFeedScreen` and the Mac's chat window
/// both render `SessionFeedItem`s through this. Prompt images are the
/// one host-specific part — the phone fetches them through the mirror,
/// the Mac reads the file — so the row takes a thumbnail builder.
public struct SessionFeedRow<Thumb: View>: View {
    let item: SessionFeedItem
    let thumbnail: (String) -> Thumb
    /// Peer messages opened to their full text (keyed by time + text).
    @Binding var expandedPeers: Set<String>

    public init(item: SessionFeedItem, expandedPeers: Binding<Set<String>>,
                @ViewBuilder thumbnail: @escaping (String) -> Thumb) {
        self.item = item
        self._expandedPeers = expandedPeers
        self.thumbnail = thumbnail
    }

    public var body: some View {
        switch item.kind {
        case .user where item.sender != nil:
            peerMessage(sender: item.sender ?? "peer")
        case .user:
            let (text, attached) = FeedRows.splitAttached(item.text)
            let images = item.images ?? []
            // A file shown as a thumbnail needs no paperclip line.
            let files = attached.filter { name in !images.contains { $0.hasSuffix("-" + name) } }
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    // Skill bodies and pasted notes arrive as user turns and are
                    // markdown too (phone screenshot 2026-09-04: "Md not shown").
                    if !text.isEmpty { MarkdownText(text: text) }
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(images, id: \.self) { thumbnail($0) }
                        }
                    }
                    ForEach(files, id: \.self) { name in
                        Label(name, systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant, .result:
            HStack {
                MarkdownText(text: item.text)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        case .tool:
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption2)
                    .foregroundStyle(FeedRows.hasErrors(item) ? Color.red : Color.primary)
                Text("\(item.toolName ?? "Tool") · \(item.text)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(.quaternary, in: Capsule())
        case .permission:
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(item.toolName ?? "Tool") wants to run: \(item.text)")
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(10)
            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        case .question:
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text).font(.subheadline.weight(.semibold))
                ForEach(item.options ?? [], id: \.self) { option in
                    Text("• \(option)").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        case .limit:
            Label(item.text, systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(.red)
        case .held:
            Label(item.text, systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.orange)
        case .agent:
            // Sub-agent card, the way Claude Code's own UI lists them
            // (user 2026-09-03 via the phone: "show sub agents like
            // Claude Code rc on mobile").
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(item.agent?.running == true ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.agent.map { "\($0.type) — \($0.description)" } ?? item.text)
                        .font(.subheadline.weight(.semibold))
                    if let agent = item.agent {
                        Text(FeedRows.agentStatus(agent))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        case .other:
            // A newer Mac's item kind: the text still reads.
            Text(item.text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func peerMessage(sender: String) -> some View {
        let key = "\(item.at?.timeIntervalSince1970 ?? 0)|\(item.text.prefix(40))"
        let open = expandedPeers.contains(key)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("Message from @\(sender)")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            if open {
                Text(item.text).font(.callout).textSelection(.enabled)
            } else {
                Text(item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? item.text)
                    .font(.callout).italic().foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if open { expandedPeers.remove(key) } else { expandedPeers.insert(key) }
            }
        }
    }
}

/// Text helpers the feed rows share with their hosts.
public enum FeedRows {
    /// The Core's grouped chip ends "(×6 · 3 errors)".
    public static func hasErrors(_ item: SessionFeedItem) -> Bool {
        item.text.hasSuffix(" error)") || item.text.hasSuffix(" errors)")
    }

    /// "[attached: /a/x.jpg, /b/y.pdf]" at the end of a sent message
    /// (SessionInput.deliver's wire form) becomes chips with the file
    /// names; the Mac-side paths mean nothing on the phone.
    public static func splitAttached(_ text: String) -> (String, [String]) {
        guard let range = text.range(of: "[attached: ", options: .backwards),
              text.hasSuffix("]") else { return (text, []) }
        let list = text[range.upperBound..<text.index(before: text.endIndex)]
        let names = list.split(separator: ", ").map { path -> String in
            let file = String(path).split(separator: "/").last.map(String.init) ?? String(path)
            // Strip the UUID prefix deliver() adds: "<uuid>-photo-1234.jpg".
            let parts = file.split(separator: "-", maxSplits: 5, omittingEmptySubsequences: false)
            return parts.count > 5 ? parts[5...].joined(separator: "-") : file
        }
        let body = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (body == "Please look at the attached file(s):" ? "" : body, names)
    }

    public static func agentStatus(_ agent: SessionFeedItem.Agent) -> String {
        var parts = ["\(agent.toolCalls) tool call\(agent.toolCalls == 1 ? "" : "s")"]
        if let last = agent.lastTool { parts.append("last: \(last)") }
        parts.append(agent.running ? "running" : "done")
        return parts.joined(separator: " · ")
    }

    /// The prompt a session is parked on, when its newest item is one.
    public static func pendingPrompt(_ feed: SessionFeed?) -> SessionFeedItem? {
        guard feed?.waiting == true, let last = feed?.items.last,
              last.kind == .permission || last.kind == .question else { return nil }
        return last
    }
}
