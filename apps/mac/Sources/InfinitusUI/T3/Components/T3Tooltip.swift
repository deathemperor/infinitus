import SwiftUI

/// T3's tooltip. AppKit renders it as the window's help tag, so the Mac kit
/// hands the text to `.help` rather than building a second popover.
public struct T3Tooltip<Content: View>: View {
    let text: String
    let content: Content
    public init(_ text: String, @ViewBuilder content: () -> Content) {
        self.text = text; self.content = content()
    }
    public var body: some View { content.help(text) }
}
