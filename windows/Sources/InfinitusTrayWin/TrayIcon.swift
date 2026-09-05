import Foundation
import WinSDK

/// The notification-area icon, drawn with GDI rather than shipped as an
/// .ico — one less build artefact, and the colour can follow fleet state.
/// Two rings, the Infinitus glyph's shape at 16 px: amber when a session
/// is busy, slate when everything idles.
enum TrayIcon {
    static let busyColor: UInt32 = 0xFFFF_9500     // amber (BGRA, opaque)
    static let idleColor: UInt32 = 0xFF8E_8E93     // slate

    /// An icon coloured for the given state, sized to `side`×`side` (default 16×16).
    /// The caller owns the handle and must `DestroyIcon` it.
    static func make(busy: Bool, side: Int32 = 16) -> HICON? {
        guard let screen = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, screen) }
        guard let memory = CreateCompatibleDC(screen) else { return nil }
        defer { DeleteDC(memory) }

        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = side
        info.bmiHeader.biHeight = -side          // top-down rows
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)

        var raw: UnsafeMutableRawPointer?
        guard let color = CreateDIBSection(memory, &info, DWORD(DIB_RGB_COLORS), &raw, nil, 0),
              let pixels = raw?.assumingMemoryBound(to: UInt32.self)
        else { return nil }

        // The AND mask is ignored for 32-bit alpha icons but must exist.
        let maskStride = ((side + 15) / 16) * 2
        var mask = [UInt8](repeating: 0, count: Int(maskStride * side))

        let centre = Double(side - 1) / 2
        let gap = Double(side) * 0.18
        let radius = Double(side) * 0.20
        let stroke = max(1.0, Double(side) * 0.07)
        let ink = busy ? busyColor : idleColor
        for y in 0..<Int(side) {
            for x in 0..<Int(side) {
                let left = hypot(Double(x) - (centre - gap), Double(y) - centre)
                let right = hypot(Double(x) - (centre + gap), Double(y) - centre)
                let onRing = abs(left - radius) <= stroke || abs(right - radius) <= stroke
                pixels[y * Int(side) + x] = onRing ? ink : 0
            }
        }

        let maskBitmap = mask.withUnsafeMutableBufferPointer {
            CreateBitmap(side, side, 1, 1, $0.baseAddress)
        }
        guard let maskBitmap else {
            DeleteObject(color)
            return nil
        }
        defer {
            DeleteObject(color)
            DeleteObject(maskBitmap)
        }
        var icon = ICONINFO(fIcon: true, xHotspot: 0, yHotspot: 0,
                            hbmMask: maskBitmap, hbmColor: color)
        return CreateIconIndirect(&icon)
    }
}
