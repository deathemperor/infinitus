import SwiftUI

/// SF Symbols T3's mobile app draws (`grep -rhoE 'name="[a-z0-9.]+"' apps/mobile/src`).
public enum T3Symbol: String, CaseIterable, Sendable {
    case archiveboxFill = "archivebox.fill"
    case arrowClockwise = "arrow.clockwise"
    case arrowDownRightAndArrowUpLeft = "arrow.down.right.and.arrow.up.left"
    case arrowTriangleBranch = "arrow.triangle.branch"
    case arrowTurnLeftUp = "arrow.turn.left.up"
    case arrowUpRight = "arrow.up.right"
    case checkmarkCircle = "checkmark.circle"
    case checkmark
    case chevronDown = "chevron.down"
    case chevronLeft = "chevron.left"
    case chevronRight = "chevron.right"
    case chevronUp = "chevron.up"
    case docOnDoc = "doc.on.doc"
    case docText = "doc.text"
    case ellipsis
    case exclamationmarkTriangle = "exclamationmark.triangle"
    case folderBadgePlus = "folder.badge.plus"
    case folder
    case gearshape
    case infoCircle = "info.circle"
    case link
    case magnifyingglass
    case pencil
    case pin
    case play
    case plus
    case point3ConnectedTrianglepathDotted = "point.3.connected.trianglepath.dotted"
    case safari
    case sidebarLeft = "sidebar.left"
    case squareAndPencil = "square.and.pencil"
    case textformatSizeLarger = "textformat.size.larger"
    case textformatSizeSmaller = "textformat.size.smaller"
    case ticket
    case trash
    case trayAndArrowUp = "tray.and.arrow.up"
    case wifiSlash = "wifi.slash"
    case xmarkCircleFill = "xmark.circle.fill"
    case xmark

    public var systemName: String { rawValue }
    public var image: Image { Image(systemName: rawValue) }
}
