import SwiftUI
import AppKit
import InfinitusUI

/// The prompt editor (`ComposerPromptEditor.tsx:1971-1990`) as an `NSTextView`.
///
/// Why not SwiftUI: `TextEditor` has no submit at all (⏎ always inserts a
/// newline) and `TextField(axis: .vertical)`'s `onSubmit` cannot tell ⏎ from
/// ⇧⏎ — AppKit binds both to `insertNewline:` and only ⌥⏎ to
/// `insertNewlineIgnoringFieldEditor:` — nor can either intercept ⌘V to claim
/// a pasted screenshot, or ↑/↓ for prompt recall. `doCommand(by:)` on an
/// `NSTextView` answers all four.
struct T3PromptField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// The insertion point in UTF-16 code units — `NSTextView`'s own unit, and
    /// the one `T3ComposerTrigger` reads the prompt at. Reported by the view.
    @Binding var caret: Int
    /// A caret the composer asks for (after an insertion); taken and cleared.
    @Binding var caretRequest: Int?
    /// A one-shot focus request; `onFocusHandled` clears it once taken.
    let focus: Bool
    /// Whether prompt recall is already walking the history — ↑ from a
    /// non-empty field only steps when it is (`composerPromptHistory.ts:196`).
    let recalling: Bool
    let onFocusHandled: () -> Void
    /// ⏎. The result says whether the composer sent — either way the newline
    /// stays out of the field (⇧⏎ is the newline); a future overlay that owns
    /// ⏎ (a command menu) returns false to swallow it without sending.
    let onSubmit: () -> Bool
    /// ↑/↓/⏎/⇥/⎋ offered to an open menu first (`onComposerCommandKey`,
    /// `ChatComposer.tsx:3080-3125`); true = the menu took the key.
    let onMenuKey: (T3ComposerMenuKey) -> Bool
    /// −1 = older, +1 = newer; false leaves the key to normal caret movement.
    let onRecall: (Int) -> Bool
    /// True when the paste was claimed as attachments.
    let onPaste: () -> Bool

    /// `[font-size:var(--font-size-prompt,0.875rem)]` with `leading-relaxed`
    /// (`ComposerPromptEditor.tsx:1973`, `:1982`) — 14 pt on a 1.625 line box.
    private static let fontSize: Double = 14
    private static let lineHeightMultiple: Double = 1.625
    /// `whitespace-pre-wrap` inside the body's own padding: the text view adds
    /// none of its own beyond the container's line-fragment padding.
    private static let inset = NSSize(width: 0, height: 0)

    func makeNSView(context: Context) -> NSScrollView {
        let view = T3PromptTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = Self.inset
        // The canonical text-view-in-a-scroll-view setup: the container
        // tracks the view's width and the view grows with its text, so the
        // string lays out from the top and overflow scrolls.
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.font = .systemFont(ofSize: Self.fontSize)
        view.defaultParagraphStyle = Self.paragraphStyle
        view.typingAttributes = Self.attributes
        view.textColor = NSColor(context.environment.t3.web.foreground.color)
        view.placeholder = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: Self.fontSize),
            .foregroundColor: NSColor(context.environment.t3.web.placeholder.color),
            .paragraphStyle: Self.paragraphStyle,
        ])
        view.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? T3PromptTextView else { return }
        context.coordinator.parent = self
        // Only when it differs: an unconditional assignment would reset the
        // caret and the undo stack on every unrelated republish.
        if view.string != text {
            view.string = text
            view.needsDisplay = true
        }
        // The caret only moves when it was asked to: assigning it on every
        // pass would fight typing.
        if let request = caretRequest {
            let location = max(0, min((view.string as NSString).length, request))
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.scrollRangeToVisible(NSRange(location: location, length: 0))
            // Off the update pass: the delegate callback `setSelectedRange`
            // fires runs INSIDE `updateNSView`, and a `@State` write there is
            // dropped — the caret would stay where the last keystroke left it
            // and no menu would open for a restored draft.
            DispatchQueue.main.async {
                caret = location
                caretRequest = nil
            }
        }
        view.textColor = NSColor(context.environment.t3.web.foreground.color)
        view.typingAttributes = Self.attributes
        if focus {
            if view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
            DispatchQueue.main.async { onFocusHandled() }
        }
    }

    /// The editor grows with its text between `min-h-17.5` (70) and `max-h-50`
    /// (200) and scrolls past that (`overflow-y-auto`,
    /// `ComposerPromptEditor.tsx:1982`) — measured from the string rather than
    /// the live layout so no measurement writes back into the view.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // A pass may propose no width at all; 320 wraps narrower than the
        // real card, so such a pass can only over-report a line, and the
        // next (sized) pass corrects it.
        let width = proposal.width ?? 320
        let padding = ((nsView.documentView as? NSTextView)?.textContainer?.lineFragmentPadding ?? 5) * 2
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width - padding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: Self.attributes)
        // `boundingRect` ignores a trailing newline; the caret still needs its
        // line.
        let trailing = text.hasSuffix("\n") ? Self.fontSize * Self.lineHeightMultiple : 0
        return CGSize(width: width, height: min(200, max(70, ceil(bounds.height + trailing))))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }
    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraphStyle]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: T3PromptField
        init(_ parent: T3PromptField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? T3PromptTextView else { return }
            parent.text = view.string
            parent.caret = view.selectedRange().location
            view.needsDisplay = true   // the placeholder appears and disappears
        }

        /// A trigger is read at the caret, so moving it alone (a click, ← / →)
        /// opens and closes the menus just as typing does.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? T3PromptTextView else { return }
            let location = view.selectedRange().location
            if parent.caret != location { parent.caret = location }
        }
    }
}

/// The field itself: draws the placeholder an `NSTextView` has no property
/// for, and routes the four keys SwiftUI cannot reach.
private final class T3PromptTextView: NSTextView {
    var placeholder: NSAttributedString?
    weak var coordinator: T3PromptField.Coordinator?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        placeholder.draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                                     y: textContainerInset.height))
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // AppKit sends `insertNewline:` for both ⏎ and ⇧⏎ — only the event
            // tells them apart (`composerSubmissionIntentForEnter`,
            // `composer-logic.ts:33-34`: shift is a newline, never a send).
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                super.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
                return
            }
            // An open menu takes ⏎ to pick its row, and nothing is sent
            // (`onComposerCommandKey`, `ChatComposer.tsx:3104-3106`).
            if coordinator?.parent.onMenuKey(.pick) == true { return }
            _ = coordinator?.parent.onSubmit()
            return
        case #selector(NSResponder.insertTab(_:)):
            // ⇥ picks as well (`:3104`); with no menu open it stays AppKit's.
            if coordinator?.parent.onMenuKey(.pick) == true { return }
        case #selector(NSResponder.cancelOperation(_:)):
            // Ours: ⎋ shuts the menu (upstream has none to shut, `:2023`).
            if coordinator?.parent.onMenuKey(.dismiss) == true { return }
        case #selector(NSResponder.moveUp(_:)):
            if coordinator?.parent.onMenuKey(.up) == true { return }
            if canRecall, coordinator?.parent.onRecall(-1) == true { return }
        case #selector(NSResponder.moveDown(_:)):
            if coordinator?.parent.onMenuKey(.down) == true { return }
            if coordinator?.parent.recalling == true, coordinator?.parent.onRecall(1) == true { return }
        default:
            break
        }
        super.doCommand(by: selector)
    }

    /// Backward recall starts from an empty prompt and continues while
    /// browsing (`stepComposerPromptHistory`, `composerPromptHistory.ts:196`).
    private var canRecall: Bool {
        string.isEmpty || coordinator?.parent.recalling == true
    }

    override func paste(_ sender: Any?) {
        if coordinator?.parent.onPaste() == true { return }
        super.paste(sender)
    }

    /// ⌥⏎ keeps AppKit's own meaning (a newline) — `insertNewlineIgnoringFieldEditor:`
    /// arrives here and is passed straight through by `doCommand(by:)`.
    override var acceptsFirstResponder: Bool { true }
}
