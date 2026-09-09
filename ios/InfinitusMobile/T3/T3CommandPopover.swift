import SwiftUI
import InfinitusCore
import InfinitusUI

/// `detectComposerTrigger` (`composerTrigger.ts`) for the slash case: the
/// current line, from its start to the cursor, is `/` plus non-spaces —
/// the query is what follows the slash. The phone's editor reports no
/// cursor, so the cursor is the end of the text, which is where a phone
/// types. A space after the command closes the menu, as upstream.
enum T3SlashTrigger {
    struct Match: Equatable {
        let query: String
        let range: Range<String.Index>
    }

    static func detect(_ text: String) -> Match? {
        let lineStart = text.lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
        let line = text[lineStart...]
        guard line.hasPrefix("/"), !line.contains(where: \.isWhitespace) else { return nil }
        return Match(query: String(line.dropFirst()), range: lineStart..<text.endIndex)
    }

    /// The draft with the trigger replaced by the command's insertion (`/name `).
    static func apply(_ command: SlashCommand, to text: String, match: Match) -> String {
        text.replacingCharacters(in: match.range, with: command.insertion)
    }
}

/// `ComposerCommandPopover.tsx` for the slash trigger: the "Commands"
/// eyebrow, rows of terminal glyph · `/name` · description on a glass
/// surface, at most 180 pt tall; "Loading…" / "No matching commands."
/// when there is nothing to list.
struct T3CommandPopover: View {
    let items: [SlashCommand]
    let loading: Bool
    let select: (SlashCommand) -> Void
    @Environment(\.t3) private var t3
    /// The rows' natural height: the list hugs it up to `max-h-[180px]`.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        T3GlassSurface {
            VStack(alignment: .leading, spacing: 0) {
                Text("COMMANDS").font(T3Font.mobile(.xxxs, .bold)).tracking(0.8)
                    .foregroundStyle(t3.mobile.foregroundMuted.color)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                if items.isEmpty {
                    Text(loading ? "Loading…" : "No matching commands.")
                        .font(T3Font.mobile(.xs)).foregroundStyle(t3.mobile.foregroundTertiary.color)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(items) { command in
                                row(command)
                                if command.id != items.last?.id {
                                    Rectangle().fill(t3.mobile.border.color).frame(height: 1 / 3)
                                }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    }
                    .frame(height: min(rowsHeight, 180))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ command: SlashCommand) -> some View {
        Button { select(command) } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal").font(.system(size: 14)).foregroundStyle(t3.mobile.iconSubtle.color)
                Text("/" + command.name).font(T3Font.mobile(.base, .medium)).lineLimit(1)
                    .foregroundStyle(t3.mobile.foreground.color).layoutPriority(1)
                if !command.description.isEmpty {
                    Text(command.description).font(T3Font.mobile(.xs)).lineLimit(1)
                        .foregroundStyle(t3.mobile.foregroundMuted.color)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
