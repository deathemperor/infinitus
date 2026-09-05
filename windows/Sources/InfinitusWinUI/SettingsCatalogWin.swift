import Foundation
import InfinitusCore

/// Command ID block allocation and pure sidebar data for the Windows Settings shell.
/// No WinSDK imports here so this remains fully testable without HWND.
public enum PaneIDs {
    /// 512 command ids per pane — far more than any pane needs, and the
    /// arithmetic stays readable in a debugger.
    public static let stride: Int32 = 512
    public static let base: Int32 = 0x1000

    public static func block(_ index: Int32) -> Int32 {
        base + index * stride
    }

    public static func paneIndex(for commandID: Int32) -> Int32? {
        guard commandID >= base else { return nil }
        return (commandID - base) / stride
    }
}

public struct PaneDescriptor: Sendable {
    public enum Section: Sendable, Equatable {
        case general
        case engines
    }

    public struct ProviderBadge: Sendable, Equatable {
        public var live: Bool
        public var placeholder: Bool

        public init(live: Bool = false, placeholder: Bool = false) {
            self.live = live
            self.placeholder = placeholder
        }
    }

    public let id: String
    public let title: String
    public let glyph: String
    public let tintRGB: (r: UInt8, g: UInt8, b: UInt8)
    public let keywords: [String]
    public var section: Section
    public var badge: (@Sendable () -> ProviderBadge)?

    public init(
        id: String,
        title: String,
        glyph: String,
        tintRGB: (r: UInt8, g: UInt8, b: UInt8),
        keywords: [String],
        section: Section = .general,
        badge: (@Sendable () -> ProviderBadge)? = nil
    ) {
        self.id = id
        self.title = title
        self.glyph = glyph
        self.tintRGB = tintRGB
        self.keywords = keywords
        self.section = section
        self.badge = badge
    }
}

public enum SettingsCatalogWin {
    /// Pure match against descriptor
    public static func matches(_ descriptor: PaneDescriptor, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if descriptor.title.range(of: q, options: .caseInsensitive) != nil { return true }
        return descriptor.keywords.contains { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    public static func filter(_ descriptors: [PaneDescriptor], query: String) -> [PaneDescriptor] {
        descriptors.filter { matches($0, query: query) }
    }

    /// Pure scroll range clamping logic
    public static func clampScroll(offset: Int32, contentHeight: Int32, viewportHeight: Int32) -> (offset: Int32, maxOffset: Int32) {
        let maxOffset = max(0, contentHeight - viewportHeight)
        let clamped = min(max(0, offset), maxOffset)
        return (clamped, maxOffset)
    }

    /// Card grid columns calculation
    public static func cardGridColumns(contentWidth: Int32, pad: Int32 = 16, nominalCardWidth: Int32 = 300, gap: Int32 = 10) -> Int32 {
        let availW = max(nominalCardWidth, contentWidth - pad * 2)
        return max(1, (availW + gap) / (nominalCardWidth + gap))
    }

    /// Card grid content height calculation
    public static func cardGridContentHeight(itemCount: Int, columns: Int32, cardHeight: Int32 = 120, gap: Int32 = 10, chromeHeight: Int32 = 240) -> Int32 {
        guard columns > 0 else { return chromeHeight }
        let rows = Int32(ceil(Double(itemCount) / Double(columns)))
        return rows * (cardHeight + gap) + chromeHeight
    }
}
