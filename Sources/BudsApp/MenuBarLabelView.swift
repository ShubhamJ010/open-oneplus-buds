import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            IconKit.menuBarMark()
                .renderingMode(.template)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .symbolEffect(
                    .pulse.byLayer,
                    options: .repeating,
                    isActive: model.isMediaPlaying
                )

            if let text = model.menuBatteryText {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuAccessibilityLabel)
    }
}
