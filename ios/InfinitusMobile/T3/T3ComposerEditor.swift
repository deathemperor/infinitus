import SwiftUI
import UIKit

/// T3's native composer editor (`modules/t3-composer-editor/ios/
/// T3ComposerEditorView.swift`) as a SwiftUI view, C-2's port: DM Sans
/// 16 on a fixed 23 pt line, the theme's foreground and placeholder
/// colors, no chrome of its own — the capsule around it is the chrome.
/// Collapsed it is one centered line 36 pt tall (6 pt insets); expanded
/// it grows with its text between `minHeight` and `maxHeight` and
/// scrolls past that. Image pastes go to `onPasteImage`, as the feed's
/// `ImagePasteTextView` does; skill chips and file tokens are not
/// ported — the phone has neither.
struct T3ComposerEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var expanded: Bool
    var textColor: Color
    var placeholderColor: Color
    var onPasteImage: (UIImage) -> Void

    static let fontSize: CGFloat = 16
    static let lineHeight: CGFloat = 23
    static let collapsedHeight: CGFloat = 36
    static let collapsedInset: CGFloat = 6
    static let expandedMin: CGFloat = 72
    static let expandedMax: CGFloat = 160
    static let expandedInset: CGFloat = 4

    static var font: UIFont { UIFont(name: "DMSans-Regular", size: fontSize) ?? .systemFont(ofSize: fontSize) }

    static func attributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    func makeUIView(context: Context) -> T3EditorTextView {
        let view = T3EditorTextView()
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = false
        view.tintColor = .systemBlue
        view.delegate = context.coordinator
        view.placeholderLabel = context.coordinator.placeholderLabel
        view.addSubview(context.coordinator.placeholderLabel)
        apply(to: view, context: context)
        view.text = text
        return view
    }

    func updateUIView(_ view: T3EditorTextView, context: Context) {
        context.coordinator.parent = self
        apply(to: view, context: context)
        if view.text != text { view.text = text }
        context.coordinator.placeholderLabel.isHidden = !text.isEmpty
        // Never move first responder inside SwiftUI's update pass (#294).
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { if !view.isFirstResponder { view.becomeFirstResponder() } }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { if view.isFirstResponder { view.resignFirstResponder() } }
        }
        view.isScrollEnabled = expanded && context.coordinator.contentHeight(for: view) > Self.expandedMax
    }

    private func apply(to view: T3EditorTextView, context: Context) {
        let color = UIColor(textColor)
        view.onPasteImage = onPasteImage
        view.font = Self.font
        view.textColor = color
        view.typingAttributes = Self.attributes(color: color)
        let inset = expanded ? Self.expandedInset : Self.collapsedInset
        view.textContainerInset = UIEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        let label = context.coordinator.placeholderLabel
        label.text = placeholder
        label.font = Self.font
        label.textColor = UIColor(placeholderColor)
        view.setNeedsLayout()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: T3EditorTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        guard expanded else { return CGSize(width: width, height: Self.collapsedHeight) }
        let content = context.coordinator.contentHeight(for: uiView, width: width)
        return CGSize(width: width, height: min(max(content, Self.expandedMin), Self.expandedMax))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: T3ComposerEditor
        let placeholderLabel = UILabel()

        init(_ parent: T3ComposerEditor) {
            self.parent = parent
            placeholderLabel.numberOfLines = 1
            placeholderLabel.isUserInteractionEnabled = false
        }

        func contentHeight(for textView: UITextView, width: CGFloat? = nil) -> CGFloat {
            textView.sizeThatFits(CGSize(width: width ?? textView.bounds.width, height: .infinity)).height
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel.isHidden = !textView.text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFocused = false }
        }
    }
}

/// The editor's text view: places the placeholder once it has a width
/// (T3's `layoutSubviews` does the same), image pastes as the feed's.
final class T3EditorTextView: ImagePasteTextView {
    weak var placeholderLabel: UILabel?

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel?.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                                         width: max(0, bounds.width - textContainerInset.left - textContainerInset.right),
                                         height: T3ComposerEditor.lineHeight)
    }
}
