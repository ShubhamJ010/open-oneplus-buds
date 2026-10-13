import SwiftUI
import Combine

struct MenuBarLabelView: View {
    @EnvironmentObject var model: AppModel
    @State private var animPhase: Int = 0

    // Drives frame-by-frame menu bar animation when media is playing
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            IconKit.menuBarMark()
                .renderingMode(.template)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .opacity(model.isMediaPlaying ? pulseOpacity : 1.0)
                .scaleEffect(model.isMediaPlaying ? pulseScale : 1.0)

            if model.isMediaPlaying {
                EqualizerMiniBars(phase: animPhase)
                    .foregroundStyle(.primary)
            }

            if let text = model.menuBatteryText {
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuAccessibilityLabel)
        .onReceive(timer) { _ in
            if model.isMediaPlaying {
                animPhase = (animPhase + 1) % 6
            }
        }
    }

    private var pulseOpacity: Double {
        switch animPhase {
        case 0, 3: return 1.0
        case 1, 4: return 0.85
        default: return 0.7
        }
    }

    private var pulseScale: CGFloat {
        switch animPhase {
        case 0, 3: return 1.04
        case 1, 4: return 1.0
        default: return 0.97
        }
    }
}

private struct EqualizerMiniBars: View {
    let phase: Int

    private static let barHeights: [[CGFloat]] = [
        [3.0, 9.0, 5.0],
        [6.0, 4.0, 8.0],
        [9.0, 10.0, 4.0],
        [5.0, 7.0, 9.0],
        [8.0, 3.0, 6.0],
        [4.0, 8.0, 3.0]
    ]

    var body: some View {
        let heights = Self.barHeights[phase % Self.barHeights.count]
        HStack(alignment: .bottom, spacing: 1.5) {
            RoundedRectangle(cornerRadius: 0.8)
                .frame(width: 2.0, height: heights[0])
            RoundedRectangle(cornerRadius: 0.8)
                .frame(width: 2.0, height: heights[1])
            RoundedRectangle(cornerRadius: 0.8)
                .frame(width: 2.0, height: heights[2])
        }
        .frame(height: 11, alignment: .bottom)
        .padding(.horizontal, 1)
    }
}
