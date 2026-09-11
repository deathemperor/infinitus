/// T3's `buttonVariants` size map (apps/web/src/components/ui/button.tsx),
/// as numbers the SwiftUI kit can lay out with. The Mac renders the `sm:`
/// breakpoint — the desktop half of each class pair.
public enum T3ButtonMetrics {
    public enum Size: Sendable, CaseIterable { case xs, sm, `default`, icon }

    /// `default: "h-9 … sm:h-8"`, `sm: "h-8 … sm:h-7"`, `xs: "h-7 … sm:h-6"`
    /// (`button.tsx:36`), `icon: "size-9 sm:size-8"`.
    public static func height(_ size: Size) -> Double {
        switch size {
        case .default: return 32
        case .sm: return 28
        case .xs: return 24
        case .icon: return 32
        }
    }

    /// `px-[calc(--spacing(n)-1px)]` verbatim — the class's own arithmetic is
    /// the number, not the step it subtracts from. The 1 px it takes off is
    /// the outline, which `button.tsx` paints as a `before:` overlay
    /// (`before:rounded-[calc(var(--radius-md)-1px)]`) and SwiftUI as a
    /// `.stroke` on the frame's edge: neither consumes layout width, so the
    /// remainder is the whole content inset. Measured on the 2x Mac
    /// reference: the "Add action" pill is 94 pt around 80 pt of content, i.e.
    /// 7 a side. `icon` is a square, no padding.
    public static func horizontalPadding(_ size: Size) -> Double {
        switch size {
        case .default: return 11  // px-[calc(--spacing(3)-1px)]
        case .sm: return 9        // px-[calc(--spacing(2.5)-1px)]
        case .xs: return 7        // px-[calc(--spacing(2)-1px)] (`button.tsx:36`)
        case .icon: return 0
        }
    }
}
