import Foundation
import InfinitusCore
import InfinitusWinUI
import WinSDK

/// Generic placeholder pane for wave-01 panes that are not yet implemented.
public final class PlaceholderPane: SettingsPane {
    public let descriptor: PaneDescriptor
    public static var descriptor: PaneDescriptor {
        PaneDescriptor(id: "placeholder", title: "Placeholder", glyph: "P", tintRGB: (128, 128, 128), keywords: [])
    }

    private var ctx: PaneContext?
    private var labelHwnd: HWND?

    public init(descriptor: PaneDescriptor) {
        self.descriptor = descriptor
    }

    public func attach(host: HWND, ctx: PaneContext) {
        self.ctx = ctx
        labelHwnd = PaneControls.label(descriptor.title, in: ctx, x: 0, y: 0, w: 0, h: 0, bold: true)
    }

    public func layout(width: Int32, height: Int32) {
        guard let ctx else { return }
        let pad = ctx.metrics.pad
        if let h = labelHwnd {
            MoveWindow(h, pad, pad, width - pad * 2, ctx.metrics.px(30), true)
        }
        PaneHost.setContentHeight(ctx.host, ctx.metrics.px(100))
    }

    public func activate() {}
    public func deactivate() {}
    public func command(id: Int32, code: UINT, from: HWND?) -> Bool { false }
    public func notify(_ header: UnsafePointer<NMHDR>) -> Bool { false }
    public func drawItem(_ item: UnsafePointer<DRAWITEMSTRUCT>) -> Bool { false }
    public func contentHeight(width: Int32) -> Int32 {
        guard let ctx else { return 100 }
        return ctx.metrics.px(100)
    }
}
