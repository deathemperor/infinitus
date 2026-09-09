import Foundation

/// `components/composerFooterLayout.ts`, the part the scroll-to-end pill needs:
/// how far above the timeline's bottom edge the pill has to sit so it clears
/// the composer overlay without floating away from it.
///
/// Only `resolveScrollToEndClearance` (`:195-211`) is ported — the file's other
/// helpers (`resolveComposerTimelineInset`, the resting-controls hysteresis,
/// the image-preview counts) belong to the resting composer, which this port
/// does not build.
public enum T3ComposerFooterLayout {
    /// One attached drawer's box, in the overlay's own coordinates: `top` is
    /// what decides the clearance, `left`/`right` whether it is in the pill's
    /// way at all.
    public struct Attachment: Sendable, Equatable {
        public let top: Double
        public let left: Double
        public let right: Double
        public init(top: Double, left: Double, right: Double) {
            self.top = top; self.left = left; self.right = right
        }
    }

    /// `resolveScrollToEndClearance` verbatim: the overlay's height, minus the
    /// distance from its own content top down to the topmost drawer that
    /// actually sits under the pill.
    ///
    /// The subtraction is what "keep the button close to the composer" means:
    /// a drawer docked BESIDE the composer (upstream's `ComposerBanner.Dock`
    /// puts side tabs there) raises the overlay's box without raising anything
    /// under the pill, and the pill would drift up with it. A drawer the pill
    /// does overlap horizontally cannot be crossed, so it keeps the full
    /// height. With no drawer at all the clearance is the overlay's height.
    ///
    /// - Parameters:
    ///   - overlayHeight: the composer overlay's measured height.
    ///   - mainSurfaceTop: the top of the composer's own card.
    ///   - buttonLeft/buttonRight: the pill's horizontal span.
    ///   - attachments: every attached drawer in the overlay.
    public static func scrollToEndClearance(overlayHeight: Double,
                                            mainSurfaceTop: Double,
                                            buttonLeft: Double,
                                            buttonRight: Double,
                                            attachments: [Attachment]) -> Double {
        var contentTop = mainSurfaceTop
        var top = contentTop
        for attachment in attachments {
            contentTop = min(contentTop, attachment.top)
            if attachment.left < buttonRight, attachment.right > buttonLeft {
                top = min(top, attachment.top)
            }
        }
        return (overlayHeight - (top - contentTop)).rounded(.up)
    }
}
