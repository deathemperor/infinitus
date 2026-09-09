import SwiftUI
import InfinitusCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// T3 typography (spec §3.2). DM Sans is registered by the phone app
/// (PostScript names below, agreed with Infi3); when it is missing —
/// the Mac, a stripped build — the system face steps in.
public enum T3Font {
    public enum Weight: Sendable { case regular, medium, bold }

    /// The phone's Appearance → Text size as a factor on every mobile step
    /// (upstream `appearancePreferences.ts`: `baseFontSize / DEFAULT_BASE_FONT_SIZE`,
    /// 11…22 over 16). The phone sets it from its pref; 1 everywhere else,
    /// so the Mac paths and the parity refs are untouched.
    nonisolated(unsafe) public static var mobileScale: Double = 1
    public static let dmSansNames = ["DMSans-Regular", "DMSans-Medium", "DMSans-Bold"]

    public static func mobile(_ s: T3TypeScale.Mobile, _ w: Weight = .regular) -> Font {
        mobileLiteral(s.step.size, w)
    }
    public static func web(_ s: T3TypeScale.Web, _ w: Weight = .regular) -> Font {
        .system(size: s.step.size, weight: systemWeight(w))
    }
    public static func webLiteral(_ size: Double, _ w: Weight = .regular) -> Font {
        .system(size: size, weight: systemWeight(w))
    }
    /// A DM Sans face at a size T3 sets literally rather than off the scale
    /// (`text-[21px]`, `text-[9px]` in CompactBrandTitle.tsx).
    public static func mobileLiteral(_ size: Double, _ w: Weight = .regular) -> Font {
        let scaled = max(8, (size * mobileScale).rounded())
        if dmSansAvailable { return .custom(dmSansName(w), fixedSize: scaled) }
        return .system(size: scaled, weight: systemWeight(w))
    }
    private static func dmSansName(_ w: Weight) -> String {
        switch w { case .regular: return dmSansNames[0]; case .medium: return dmSansNames[1]; case .bold: return dmSansNames[2] }
    }
    static func systemWeight(_ w: Weight) -> Font.Weight {
        switch w { case .regular: return .regular; case .medium: return .medium; case .bold: return .bold }
    }
    static let dmSansAvailable: Bool = {
        #if canImport(UIKit)
        return UIFont(name: "DMSans-Regular", size: 12) != nil
        #elseif canImport(AppKit)
        return NSFont(name: "DMSans-Regular", size: 12) != nil
        #else
        return false
        #endif
    }()
}

public extension View {
    /// Applies a scale step: font plus the line gap T3's line-height implies.
    func t3Text(_ s: T3TypeScale.Mobile, _ w: T3Font.Weight = .regular) -> some View {
        font(T3Font.mobile(s, w)).lineSpacing(T3TypeScale.lineSpacing(s.step) * T3Font.mobileScale)
    }
    func t3Text(_ s: T3TypeScale.Web, _ w: T3Font.Weight = .regular) -> some View {
        font(T3Font.web(s, w)).lineSpacing(T3TypeScale.lineSpacing(s.step))
    }
}
