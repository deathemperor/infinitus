/// T3's `buttonVariants` size map (apps/web/src/components/ui/button.tsx),
/// as numbers the SwiftUI kit can lay out with. The Mac renders the `sm:`
/// breakpoint — the desktop half of each class pair.
public enum T3ButtonMetrics {
    public enum Size: Sendable, CaseIterable { case sm, `default`, icon }

    /// `default: "h-9 … sm:h-8"`, `sm: "h-8 … sm:h-7"`, `icon: "size-9 sm:size-8"`.
    public static func height(_ size: Size) -> Double {
        switch size {
        case .default: return 32
        case .sm: return 28
        case .icon: return 32
        }
    }

    /// The Tailwind spacing step behind `px-[calc(--spacing(n)-1px)]`: the
    /// class subtracts the 1 px border, which SwiftUI draws on the edge, so
    /// the padding here is the whole step. `icon` is a square, no padding.
    public static func horizontalPadding(_ size: Size) -> Double {
        switch size {
        case .default: return 12  // px-3
        case .sm: return 10       // px-2.5
        case .icon: return 0
        }
    }
}
