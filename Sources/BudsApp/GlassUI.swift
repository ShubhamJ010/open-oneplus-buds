import SwiftUI

struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background {
                    shape
                        .fill(.background)
                        .overlay { shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
                }
        } else {
            content
                .glassEffect(.regular, in: shape)
        }
    }
}

struct GlassCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(14)
            .modifier(GlassSurface(shape: shape))
    }
}

struct StatusChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let kind: Kind
    var action: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero

    enum Kind {
        case idle
        case running
        case success
        case failure
    }

    var baseColor: Color {
        switch kind {
        case .idle: return .secondary
        case .running: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .success: return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .failure: return Color(red: 1.0, green: 0.38, blue: 0.38)
        }
    }

    var iconSystemName: String {
        switch kind {
        case .idle: return "circle"
        case .running: return "antenna.radiowaves.left.and.right"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        let shape = Capsule(style: .continuous)

        Group {
            if let action {
                Button(action: action) {
                    chipBody(shape: shape)
                }
                .buttonStyle(GlassPressFeedbackButtonStyle())
                .help("Tap to reconnect")
            } else {
                chipBody(shape: shape)
            }
        }
        .contentShape(shape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                hoverLocation = loc
                if !isHovered {
                    withAnimation(.spring(response: 0.20, dampingFraction: 0.80)) {
                        isHovered = true
                    }
                }
            case .ended:
                withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
                    isHovered = false
                    hoverLocation = .zero
                }
            }
        }
    }

    @ViewBuilder
    private func chipBody(shape: Capsule) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let center = hoverLocation == .zero
                ? CGPoint(x: size.width / 2, y: size.height / 2)
                : hoverLocation

            ZStack {
                // Frosted Liquid Glass Surface
                shape
                    .modifier(GlassSurface(shape: shape))
                    .overlay {
                        // Soft tinted ambient backlight
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        baseColor.opacity(isHovered ? 0.22 : 0.14),
                                        baseColor.opacity(isHovered ? 0.12 : 0.07)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }

                // Interactive specular glow tracking pointer
                if isHovered {
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.32 : 0.40),
                            baseColor.opacity(0.18),
                            .clear
                        ],
                        center: UnitPoint(
                            x: max(0, min(1, center.x / max(size.width, 1))),
                            y: max(0, min(1, center.y / max(size.height, 1)))
                        ),
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.85
                    )
                    .clipShape(shape)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }

                // Fine dual-tone rim stroke
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                baseColor.opacity(isHovered ? 0.55 : 0.30),
                                Color.white.opacity(isHovered ? 0.25 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )

                // Label Content with animated pulse dot / icon
                HStack(spacing: 5.5) {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(baseColor)

                    Text(text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            isHovered
                                ? baseColor
                                : (colorScheme == .dark ? baseColor.opacity(0.92) : baseColor)
                        )
                        .lineLimit(1)

                    if action != nil {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(baseColor.opacity(isHovered ? 0.90 : 0.60))
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .frame(height: 24)
        .fixedSize(horizontal: true, vertical: false)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isHovered)
        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: hoverLocation)
    }
}

struct GlassPressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.90 : 1.0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
