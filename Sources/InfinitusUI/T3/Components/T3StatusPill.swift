import SwiftUI
import InfinitusCore

/// T3's `<StatusPill>` (apps/mobile/src/components/StatusPill.tsx) carrying
/// a thread's status: the labels of `thread-list-v2-items.tsx`'s
/// `STATUS_LABEL_BY_STATUS` in the tones `threadPresentation.ts` resolves —
/// amber approval, indigo/primary input and work, red failure.
public struct T3StatusPill: View {
    @Environment(\.t3) private var t3
    let status: T3ThreadStatus
    public init(_ status: T3ThreadStatus) { self.status = status }
    public var body: some View {
        HStack(spacing: 4) {
            glyph.image.font(.system(size: 10, weight: .bold))
            Text(label).font(T3Font.mobile(.xs, .bold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
    }
    private var label: String {
        switch status {
        case .approval: return "Approval"
        case .input: return "Input"
        case .working: return "Working"
        case .failed: return "Failed"
        case .ready: return "Ready"
        }
    }
    private var glyph: T3Symbol {
        switch status {
        case .approval: return .exclamationmarkTriangle
        case .input: return .arrowTurnLeftUp
        case .working: return .point3ConnectedTrianglepathDotted
        case .failed: return .xmarkCircleFill
        case .ready: return .checkmarkCircle
        }
    }
    private var background: Color {
        let p = t3.mobile
        switch status {
        case .approval: return p.warning.color            // "bg-warning"
        case .failed: return p.danger.color               // "bg-danger"
        case .input, .working, .ready: return p.primary.color.opacity(0.1)  // "bg-primary/10"
        }
    }
    private var foreground: Color {
        let p = t3.mobile
        switch status {
        case .approval: return p.warningForeground.color
        case .failed: return p.dangerForeground.color
        case .input, .working, .ready: return p.foregroundSecondary.color
        }
    }
}
