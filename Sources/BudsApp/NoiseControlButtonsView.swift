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

        VStack(spacing: 0) {
            // Recessed frosted dock encapsulating the 3 modes
            HStack(spacing: 0) {
                modeDockItem(mode: .on, label: "Noise Cancellation", selection: effectiveSelection)
                modeDockItem(mode: .transparency, label: "Transparency", selection: effectiveSelection)
                modeDockItem(mode: .off, label: "Off", selection: effectiveSelection)
            }
            .padding(6)
            .background {
                let dockShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
                dockShape
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.035 : 0.05))
                    .overlay {
                        dockShape
                            .strokeBorder(
                                Color.white.opacity(colorScheme == .dark ? 0.09 : 0.12),
                                lineWidth: 1
                            )
                    }
            }
        }
        .padding(.vertical, 4)
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
    private func modeDockItem(mode: ANCMode, label: String, selection: ANCMode?) -> some View {
        let isSelected = (selection == mode)

        ANCModeDockButton(
            mode: mode,
            label: label,
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
        .frame(maxWidth: .infinity)
    }
}

private struct ANCModeDockButton: View {
    let mode: ANCMode
    let label: String
    let isSelected: Bool
    let enabled: Bool
    let reduceTransparency: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero

    private let bubbleSize: CGFloat = 48
    private let circleShape = Circle()

    /// Mode-distinct acoustic accent colors
    private var modeAccentColor: Color {
        switch mode {
        case .on:
            // Oceanic Cyan / High-Tech Acoustic Blue
            return Color(red: 0.0, green: 0.65, blue: 1.0)
        case .transparency:
            // Sunset Amber / Warm Passthrough Gold
            return Color(red: 1.0, green: 0.60, blue: 0.15)
        case .off:
            // Refined Slate Gray / Pure Silver
            return Color(white: 0.55)
        }
    }

    /// Dynamic SF Symbol for each mode, morphing states cleanly
    private var resolvedSymbol: String {
        switch mode {
        case .on:
            return "waveform.badge.minus"
        case .transparency:
            return "ear.and.waveform"
        case .off:
            return isSelected ? "circle.slash" : "circle"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                // Circular Bubble
                GeometryReader { geo in
                    let size = geo.size
                    let radius = size.width / 2
                    let center = hoverLocation == .zero ? CGPoint(x: radius, y: radius) : hoverLocation
                    let dx = (center.x - radius) / max(radius, 1)
                    let dy = (center.y - radius) / max(radius, 1)
                    let dist = min(1.0, sqrt(dx * dx + dy * dy))

                    let edgeBias = isHovered ? max(0, (dist - 0.20) / 0.80) : 0
                    let nudgeX = isHovered ? (dx * edgeBias * 1.6) : 0
                    let nudgeY = isHovered ? (dy * edgeBias * 1.6) : 0

                    ZStack {
                        // Ambient Mode-Distinct Radial Glow (Spills subtly around active or hovered bubble)
                        if isSelected || isHovered {
                            circleShape
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            modeAccentColor.opacity(isSelected ? (reduceTransparency ? 0.35 : 0.55) : 0.22),
                                            modeAccentColor.opacity(isSelected ? 0.15 : 0.05),
                                            .clear
                                        ],
                                        center: .center,
                                        startRadius: radius * 0.3,
                                        endRadius: radius * 1.4
                                    )
                                )
                                .blur(radius: isSelected ? 8 : 4)
                                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                        }

                        // Background Glass Surface
                        circleShape
                            .modifier(GlassSurface(shape: circleShape))
                            .overlay {
                                if isSelected {
                                    circleShape
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    modeAccentColor.opacity(0.85),
                                                    modeAccentColor.opacity(0.65)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                } else {
                                    circleShape
                                        .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.10))
                                }
                            }

                        // Dynamic Specular Glow tracking hover position
                        if isHovered {
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(isSelected ? 0.40 : (colorScheme == .dark ? 0.25 : 0.35)),
                                    Color.white.opacity(isSelected ? 0.12 : (colorScheme == .dark ? 0.06 : 0.10)),
                                    .clear
                                ],
                                center: UnitPoint(
                                    x: max(0, min(1, center.x / size.width)),
                                    y: max(0, min(1, center.y / size.height))
                                ),
                                startRadius: 0,
                                endRadius: size.width * 0.8
                            )
                            .clipShape(circleShape)
                            .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                        }

                        // Delicate Outer Rim Stroke
                        circleShape
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(isSelected ? 0.45 : (isHovered ? 0.32 : (colorScheme == .dark ? 0.14 : 0.18))),
                                        modeAccentColor.opacity(isSelected ? 0.40 : 0.0)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )

                        // Foreground Animated SF Symbol
                        animatedIconView
                    }
                    .frame(width: bubbleSize, height: bubbleSize)
                    .scaleEffect(isHovered ? 1.05 : 1.0)
                    .offset(x: nudgeX, y: nudgeY)
                    .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isHovered)
                    .animation(.spring(response: 0.26, dampingFraction: 0.78), value: hoverLocation)
                }
                .frame(width: bubbleSize, height: bubbleSize)

                // Integrated Mode Label
                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color.primary
                            : (isHovered ? Color.primary.opacity(0.85) : Color.secondary)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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
        .help(label)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var animatedIconView: some View {
        Group {
            switch mode {
            case .on:
                Image(systemName: resolvedSymbol)
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: isSelected)
            case .transparency:
                Image(systemName: resolvedSymbol)
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: isSelected)
            case .off:
                Image(systemName: resolvedSymbol)
            }
        }
        .symbolRenderingMode(isSelected ? .monochrome : .hierarchical)
        .foregroundStyle(
            isSelected
                ? Color.white
                : (isHovered ? Color.primary : Color.secondary)
        )
        .font(.system(size: 18, weight: .semibold))
        .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))
        .symbolEffect(.bounce.byLayer, value: isSelected)
    }
}


