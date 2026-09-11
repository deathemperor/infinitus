/// T3's type scales (spec §3.2): the phone's own (`global.css` `@theme`,
/// `src/lib/typography.ts`) and Tailwind v4's for the web client.
public enum T3TypeScale {
    public struct Step: Sendable, Equatable {
        public let size: Double
        public let lineHeight: Double
        public init(size: Double, lineHeight: Double) { self.size = size; self.lineHeight = lineHeight }
    }
    public enum Mobile: String, CaseIterable, Sendable {
        case xxxs = "3xs", xxs = "2xs", xs, sm, base, lg, xl, xxl = "2xl", xxxl = "3xl"
        public var step: Step {
            switch self {
            case .xxxs: return .init(size: 11, lineHeight: 14)
            case .xxs: return .init(size: 12, lineHeight: 16)
            case .xs: return .init(size: 13, lineHeight: 17)
            case .sm: return .init(size: 14, lineHeight: 19)
            case .base: return .init(size: 16, lineHeight: 23)
            case .lg: return .init(size: 18, lineHeight: 23)
            case .xl: return .init(size: 21, lineHeight: 28)
            case .xxl: return .init(size: 26, lineHeight: 32)
            case .xxxl: return .init(size: 30, lineHeight: 36)
            }
        }
    }
    public enum Web: String, CaseIterable, Sendable {
        case xs, sm, base, lg, xl, xxl = "2xl"
        public var step: Step {
            switch self {
            case .xs: return .init(size: 12, lineHeight: 16)
            case .sm: return .init(size: 14, lineHeight: 20)
            case .base: return .init(size: 16, lineHeight: 24)
            case .lg: return .init(size: 18, lineHeight: 28)
            case .xl: return .init(size: 20, lineHeight: 28)
            case .xxl: return .init(size: 24, lineHeight: 32)
            }
        }
    }
    /// SwiftUI's `.lineSpacing` is the extra gap, not the line height.
    public static func lineSpacing(_ s: Step) -> Double { s.lineHeight - s.size }
}
