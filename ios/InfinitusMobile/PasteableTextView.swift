import SwiftUI
import UIKit

/// SessionFeedScreen's composer field, as a UITextView: a SwiftUI
/// TextField only accepts text pastes, so the iOS keyboard's paste chip
/// ("Photo — Paste from Screenshots") did nothing (user 2026-09-04
/// "pasting an image from the keyboard chip into Reply does nothing").
/// An image paste hands the image to the screen's existing addImage; a
/// text paste falls through untouched. The text view itself decides the
/// paste: UITextView.canPerformAction(paste:) says no to an image-only
/// pasteboard even with an image-accepting pasteConfiguration, so the
/// chip and the edit menu never called paste: and a UITextPasteDelegate
/// never ran (simulator probe, 2026-09-04 "still can't paste from
/// screenshots") — ImagePasteTextView answers both itself.
struct PasteableTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var onPasteImage: (UIImage) -> Void

    static let minHeight: CGFloat = 36
    static let maxHeight: CGFloat = 120 // ~6 lines at body size

    func makeUIView(context: Context) -> UITextView {
        let view = ImagePasteTextView()
        view.onPasteImage = onPasteImage
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 6, left: 5, bottom: 6, right: 5)
        view.textContainer.lineFragmentPadding = 0
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor.separator.cgColor
        view.layer.cornerRadius = 6
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        (view as? ImagePasteTextView)?.onPasteImage = onPasteImage
        if view.text != text { view.text = text }
        // Never move first responder inside SwiftUI's update pass: the
        // keyboard's will-hide fires synchronously from resign, and the
        // safe-area inset it should shrink is mid-update, so the composer
        // stayed floating at keyboard height until the next state change —
        // the next poll, seconds later (#294, user 2026-09-07 from the phone).
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { if !view.isFirstResponder { view.becomeFirstResponder() } }
        } else if !isFocused, view.isFirstResponder {
            DispatchQueue.main.async { if view.isFirstResponder { view.resignFirstResponder() } }
        }
        view.isScrollEnabled = context.coordinator.contentHeight(for: view) > Self.maxHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let height = min(max(context.coordinator.contentHeight(for: uiView, width: width), Self.minHeight),
                          Self.maxHeight)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PasteableTextView

        init(_ parent: PasteableTextView) { self.parent = parent }

        func contentHeight(for textView: UITextView, width: CGFloat? = nil) -> CGFloat {
            textView.sizeThatFits(CGSize(width: width ?? textView.bounds.width, height: .infinity)).height
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            DispatchQueue.main.async { self.parent.isFocused = false }
        }
    }
}

/// A UITextView that takes an image paste itself. The image is read the
/// way the composer's "Paste Image" menu item reads it; a pasteboard
/// with no image pastes as text, as before.
class ImagePasteTextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // hasImages reads no content, so no paste banner until chosen.
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if UIPasteboard.general.hasImages, let image = UIPasteboard.general.image {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }
}
