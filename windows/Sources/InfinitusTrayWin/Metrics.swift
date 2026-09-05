import WinSDK

/// Geometry and scaling calculations for Win32 windows in Infinitus.
/// Handles DPI scaling (reference: 96 dpi = 1.0) so controls and drawing
/// remain crisp and appropriately sized on high-DPI displays.
public struct Metrics {
    public let scale: Double

    public init(hwnd: HWND?) {
        let dpi = hwnd.map { Double(GetDpiForWindow($0)) } ?? 96.0
        scale = max(1.0, dpi / 96.0)
    }

    public func px(_ value: Int32) -> Int32 {
        Int32((Double(value) * scale).rounded())
    }

    // MARK: - FleetWindow metrics
    public var pad: Int32 { px(12) }
    public var rowHeight: Int32 { px(46) }
    public var headerHeight: Int32 { px(30) }
    public var fleetHeaderHeight: Int32 { px(22) }
    public var footerHeight: Int32 { px(26) }
    public var barWidth: Int32 { px(84) }
    public var barHeight: Int32 { px(7) }
    public var gaugeGap: Int32 { px(14) }
    public var numberWidth: Int32 { px(18) }
    public var nameWidth: Int32 { px(150) }

    // MARK: - Settings-shell reference geometry (96 dpi)
    public var sidebarWidth: Int32   { px(215) }   // matches Mac's 215pt
    public var settingsRowHeight: Int32 { px(30) }
    public var tileSide: Int32       { px(22) }
    public var fieldHeight: Int32    { px(22) }
    public var buttonHeight: Int32   { px(26) }
    public var labelColumn: Int32    { px(200) }
    public var sectionGap: Int32     { px(14) }
}
