import SwiftUI
import BudsCore

struct NoiseControlButtonsView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    let selection: ANCMode?
    let enabled: Bool
    let setMode: (ANCMode) -> Void

    @State private var optimisticSelection: ANCMode?
    @State private var optimisticClearTask: Task<Void, Never>?

    var body: some View {
        let effectiveSelection = optimisticSelection ?? selection
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                modeButton(mode: .on, systemImage: "waveform.badge.minus", help: "Noise Cancellation", selection: effectiveSelection)
                modeButton(mode: .transparency, systemImage: "ear.and.waveform", help: "Transparency", selection: effectiveSelection)
                modeButton(mode: .off, systemImage: "circle", help: "Off", selection: effectiveSelection)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .onChange(of: selection) { _, _ in
            optimisticClearTask?.cancel()
            optimisticClearTask = nil
            optimisticSelection = nil
        }
        .onDisappear {
            optimisticClearTask?.cancel()
            optimisticClearTask = nil
        }
    }

    @ViewBuilder
    private func modeButton(mode: ANCMode, systemImage: String, help: String, selection: ANCMode?) -> some View {
        let isSelected = (selection == mode)

        ANCModeButton(
            mode: mode,
            systemImage: systemImage,
            help: help,
            isSelected: isSelected,
            enabled: enabled,
            reduceTransparency: reduceTransparency,
            colorScheme: colorScheme,
            action: {
                guard enabled else { return }
                if self.selection != mode {
                    optimisticSelection = mode
                    optimisticClearTask?.cancel()
                    optimisticClearTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        if optimisticSelection == mode {
                            optimisticSelection = nil
                        }
                    }
                    setMode(mode)
                }
            }
        )
    }
}

private struct ANCModeButton: View {
    let mode: ANCMode
    let systemImage: String
    let help: String
    let isSelected: Bool
    let enabled: Bool
    let reduceTransparency: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero

    private let size: CGFloat = 52
    private let circleShape = Circle()

    var body: some View {
        let radius = size / 2
        let center = hoverLocation == .zero ? CGPoint(x: radius, y: radius) : hoverLocation
        let dx = (center.x - radius) / radius
        let dy = (center.y - radius) / radius
        let dist = min(1.0, sqrt(dx * dx + dy * dy))

        // Hover expansion: uniform scale to 1.05, plus edge-side increase when hovered near rim
        let edgeBias = isHovered ? max(0, (dist - 0.25) / 0.75) : 0
        let scaleX = isHovered ? (1.05 + edgeBias * abs(dx) * 0.05) : 1.0
        let scaleY = isHovered ? (1.05 + edgeBias * abs(dy) * 0.05) : 1.0
        let nudgeX = isHovered ? (dx * edgeBias * 1.5) : 0
        let nudgeY = isHovered ? (dy * edgeBias * 1.5) : 0

        Button(action: action) {
            ZStack {
                // Background Glass Surface
                circleShape
                    .modifier(GlassSurface(shape: circleShape))
                    .overlay {
                        if isSelected {
                            circleShape
                                .fill(Color.accentColor.opacity(reduceTransparency ? 0.35 : 0.60))
                        } else {
                            circleShape
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.08))
                        }
                    }

                // Dynamic Specular Glow tracking hover position
                if isHovered {
                    RadialGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.35 : (colorScheme == .dark ? 0.22 : 0.30)),
                            Color.white.opacity(isSelected ? 0.10 : (colorScheme == .dark ? 0.06 : 0.10)),
                            .clear
                        ],
                        center: UnitPoint(
                            x: max(0, min(1, center.x / size)),
                            y: max(0, min(1, center.y / size))
                        ),
                        startRadius: 0,
                        endRadius: size * 0.75
                    )
                    .clipShape(circleShape)
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                }

                // Clean glass stroke
                circleShape
                    .strokeBorder(
                        Color.white.opacity(
                            isSelected
                                ? (isHovered ? 0.45 : 0.28)
                                : (isHovered ? 0.26 : (colorScheme == .dark ? 0.12 : 0.16))
                        ),
                        lineWidth: 1
                    )

                // Foreground Icon
                Image(systemName: systemImage)
                    .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : (isHovered ? Color.primary : Color.secondary)
                    )
                    .font(.system(size: 19, weight: .semibold))
            }
            .frame(width: size, height: size)
            .scaleEffect(x: scaleX, y: scaleY)
            .offset(x: nudgeX, y: nudgeY)
            .animation(.spring(response: 0.26, dampingFraction: 0.80), value: isHovered)
            .animation(.spring(response: 0.26, dampingFraction: 0.80), value: hoverLocation)
            .contentShape(circleShape)
        }
        .buttonStyle(GlassPressFeedbackButtonStyle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                if !isHovered {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.80)) {
                        isHovered = true
                    }
                }
            case .ended:
                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                    isHovered = false
                    hoverLocation = .zero
                }
            }
        }
        .help(help)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct GlassPressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
