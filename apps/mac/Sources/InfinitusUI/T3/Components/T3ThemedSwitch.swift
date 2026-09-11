import SwiftUI

/// T3's `<ThemedSwitch>` (apps/mobile/src/components/ThemedSwitch.tsx): a
/// `Toggle` wearing the `switch-*` tokens. RN tints track and thumb in both
/// states, which the built-in `.switch` style cannot (only the on-track takes
/// a `.tint`), so the style is the kit's own — same iOS metrics, 51 × 31 with
/// a 27 pt thumb, every colour from the palette.
public struct T3ThemedSwitch: View {
    @Environment(\.t3) private var t3
    @Binding var isOn: Bool
    public init(isOn: Binding<Bool>) { self._isOn = isOn }
    public var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(T3SwitchStyle(p: t3.mobile))
    }
}

struct T3SwitchStyle: ToggleStyle {
    let p: T3Theme.MobilePalette
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill((configuration.isOn ? p.switchActiveTrack : p.switchInactiveTrack).color)
                .frame(width: 51, height: 31)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill((configuration.isOn ? p.switchActiveThumb : p.switchInactiveThumb).color)
                        .frame(width: 27, height: 27)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: configuration.isOn)
    }
}
