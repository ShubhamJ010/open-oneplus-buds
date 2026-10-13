import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: model.menuBarImage)
                .renderingMode(.template)

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
