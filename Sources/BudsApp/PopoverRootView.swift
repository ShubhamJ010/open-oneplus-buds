import SwiftUI
import BudsCore
import AppKit

struct PopoverRootView: View {
    @EnvironmentObject var model: AppModel
    @State private var isQuitHovered = false
    @State private var quitHoverLocation: CGPoint = .zero
    @State private var quitSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    HeaderCardView()
                    ANCCardView()
                    BatteryCardView(
                        isQuitHovered: isQuitHovered,
                        quitHoverLocation: quitHoverLocation,
                        quitSize: quitSize
                    )
                }
            }

            QuitSectionCard(
                isHovered: $isQuitHovered,
                hoverLocation: $quitHoverLocation,
                cardSize: $quitSize
            )
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            model.onPopoverOpen()
        }
        .onDisappear {
            model.onPopoverClose()
        }
    }
}



private struct HeaderCardView: View {
    @EnvironmentObject var model: AppModel
    @State private var showDisconnectConfirm = false

    var deviceTitle: String {
        if let name = model.deviceName, !name.isEmpty {
            return name
        }
        return "Buds"
    }

    var connectionSubtitle: String {
        switch model.connection {
        case .idle:
            return "Disconnected"
        case .bluetoothOff:
            return "Bluetooth Off"
        case .bluetoothUnauthorized:
            return "Permission Needed"
        case .bluetoothUnsupported:
            return "Bluetooth Unsupported"
        case .bluetoothResetting:
            return "Bluetooth Resetting…"
        case .scanning:
            return "Searching…"
        case .connecting:
            return "Connecting…"
        case .discovering:
            return "Discovering…"
        case .authenticating:
            return "Authenticating…"
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting…"
        case .failed(let msg):
            return "Failed: \(msg)"
        }
    }

    var isReconnecting: Bool {
        switch model.connection {
        case .scanning, .connecting, .discovering, .authenticating, .reconnecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: iconName)
                        .renderingMode(.template)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 24, weight: .medium))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(isConnected ? Color.primary : Color.secondary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(deviceTitle)
                            .font(Typography.title)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusIndicatorColor)
                                .frame(width: 7, height: 7)

                            Text(connectionSubtitle)
                                .font(Typography.subtitle)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        HeaderGlassIconButton(
                            systemImage: "arrow.triangle.2.circlepath",
                            help: "Reconnect / Snatch Connection",
                            accessibilityLabel: "Reconnect",
                            rotationDegrees: isReconnecting ? 360 : 0,
                            isRotating: isReconnecting,
                            action: { model.reconnect() }
                        )

                        if isConnected {
                            HeaderGlassIconButton(
                                systemImage: "xmark",
                                help: "Disconnect",
                                accessibilityLabel: "Disconnect",
                                action: { showDisconnectConfirm.toggle() }
                            )
                            .popover(isPresented: $showDisconnectConfirm, arrowEdge: .top) {
                                DisconnectConfirmPopoverView(
                                    onCancel: { showDisconnectConfirm = false },
                                    onConfirm: {
                                        showDisconnectConfirm = false
                                        model.disconnect()
                                    }
                                )
                            }
                        }
                    }
                }

                if shouldShowNotConnected {
                    StatusChip(
                        text: notConnectedText,
                        kind: .failure,
                        action: { model.reconnect() }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .padding(.top, 2)
                }

                if needsBluetoothHelp {
                    HStack {
                        Spacer()
                        Button("Open Bluetooth Privacy") { openBluetoothPrivacy() }
                            .buttonStyle(.glass)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isConnected: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var statusIndicatorColor: Color {
        switch model.connection {
        case .connected:
            return .green
        case .connecting, .discovering, .authenticating, .reconnecting, .scanning:
            return .blue
        case .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported, .failed:
            return .red
        case .idle, .bluetoothResetting:
            return .secondary
        }
    }

    private var iconName: String {
        isConnected ? "earbuds" : "ear.trianglebadge.exclamationmark"
    }

    private var shouldShowNotConnected: Bool {
        // When actively scanning, connecting, discovering, or authenticating, the status subtitle
        // already clearly explains what's happening (e.g. "Searching…").
        // Only show error chip when actually in a failed or idle state with an error or explicit disconnect.
        guard !isConnected else { return false }
        switch model.connection {
        case .scanning, .connecting, .discovering, .authenticating, .reconnecting:
            return false
        default:
            return model.lastError != nil
        }
    }

    private var notConnectedText: String {
        if let err = model.lastError, !err.isEmpty { return err }
        return "Not connected"
    }

    private var needsBluetoothHelp: Bool {
        switch model.connection {
        case .bluetoothUnauthorized, .bluetoothOff:
            return true
        default:
            return false
        }
    }

    private func openBluetoothPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Premium Liquid Glass interactive icon button with continuous hover tracking,
/// dynamic specular sheen, fluid spring physics, and organic edge glow.
private struct HeaderGlassIconButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    var rotationDegrees: Double = 0
    var isRotating: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero

    private let buttonCornerRadius: CGFloat = 11
    private let buttonWidth: CGFloat = 36
    private let buttonHeight: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)

        Button(action: action) {
            GeometryReader { geo in
                let size = geo.size
                let center = hoverLocation == .zero
                    ? CGPoint(x: size.width / 2, y: size.height / 2)
                    : hoverLocation

                // Responsive tilt / nudge towards pointer
                let dx = (center.x - size.width / 2) / max(size.width / 2, 1)
                let dy = (center.y - size.height / 2) / max(size.height / 2, 1)
                let nudgeX = isHovered ? (dx * 0.8) : 0
                let nudgeY = isHovered ? (dy * 0.8) : 0

                ZStack {
                    // Glass backdrop layer
                    shape
                        .modifier(GlassSurface(shape: shape))
                        .overlay {
                            shape
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12))
                        }

                    // Hover Liquid Sheen / Specular reflection
                    if isHovered {
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.38 : 0.45),
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.14),
                                .clear
                            ],
                            center: UnitPoint(
                                x: max(0, min(1, center.x / max(size.width, 1))),
                                y: max(0, min(1, center.y / max(size.height, 1)))
                            ),
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.95
                        )
                        .clipShape(shape)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    }

                    // Glass highlight rim stroke
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.40 : (colorScheme == .dark ? 0.18 : 0.22)),
                                    Color.white.opacity(isHovered ? 0.16 : 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    // Foreground Icon
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.85))
                        .rotationEffect(.degrees(rotationDegrees))
                        .animation(
                            isRotating ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                            value: isRotating
                        )
                        .offset(x: nudgeX, y: nudgeY)
                }
            }
            .frame(width: buttonWidth, height: buttonHeight)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isHovered)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: hoverLocation)
            .contentShape(shape)
        }
        .buttonStyle(GlassPressFeedbackButtonStyle())
        .help(help)
        .accessibilityLabel(accessibilityLabel)
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
                withAnimation(.spring(response: 0.20, dampingFraction: 0.82)) {
                    isHovered = false
                    hoverLocation = .zero
                }
            }
        }
    }
}

/// Refined Disconnect Confirmation Popover with dark liquid glass styling,
/// mouse-tracking red radial glow, and animated interactive action buttons.
private struct DisconnectConfirmPopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @State private var isContainerHovered = false
    @State private var containerHoverLocation: CGPoint = .zero

    @State private var isCancelHovered = false
    @State private var cancelHoverLocation: CGPoint = .zero

    @State private var isConfirmHovered = false
    @State private var confirmHoverLocation: CGPoint = .zero

    private let popoverShape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    private let buttonShape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    var body: some View {
        ZStack {
            // Container background glass & mouse-tracking radial red ambient glow
            GeometryReader { geo in
                let size = geo.size
                let center = containerHoverLocation == .zero
                    ? CGPoint(x: size.width / 2, y: size.height / 2)
                    : containerHoverLocation

                ZStack {
                    // Base dark glass fill
                    popoverShape
                        .fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color(white: 0.15).opacity(0.35))

                    // Ambient red glow tracking mouse inside the popup
                    if isContainerHovered {
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.26, blue: 0.26).opacity(0.24),
                                Color(red: 0.95, green: 0.18, blue: 0.18).opacity(0.10),
                                .clear
                            ],
                            center: UnitPoint(
                                x: max(0, min(1, center.x / max(size.width, 1))),
                                y: max(0, min(1, center.y / max(size.height, 1)))
                            ),
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.70
                        )
                        .clipShape(popoverShape)
                        .transition(.opacity.animation(.easeInOut(duration: 0.20)))
                    }

                    // Subtle perimeter glass stroke
                    popoverShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isContainerHovered ? 0.22 : 0.12),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }

            // Foreground content
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(red: 1.0, green: 0.38, blue: 0.38))

                        Text("Disconnect Buds?")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                    }

                    Text("Active audio stream and controls will disconnect.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)

                HStack(spacing: 10) {
                    // Cancel Liquid Glass Button
                    Button(action: onCancel) {
                        GeometryReader { geo in
                            let size = geo.size
                            let center = cancelHoverLocation == .zero
                                ? CGPoint(x: size.width / 2, y: size.height / 2)
                                : cancelHoverLocation

                            ZStack {
                                buttonShape
                                    .fill(Color.white.opacity(isCancelHovered ? 0.16 : 0.08))

                                if isCancelHovered {
                                    RadialGradient(
                                        colors: [
                                            Color.white.opacity(0.25),
                                            Color.white.opacity(0.06),
                                            .clear
                                        ],
                                        center: UnitPoint(
                                            x: max(0, min(1, center.x / max(size.width, 1))),
                                            y: max(0, min(1, center.y / max(size.height, 1)))
                                        ),
                                        startRadius: 0,
                                        endRadius: max(size.width, size.height) * 0.8
                                    )
                                    .clipShape(buttonShape)
                                }

                                buttonShape
                                    .strokeBorder(
                                        Color.white.opacity(isCancelHovered ? 0.28 : 0.12),
                                        lineWidth: 1
                                    )

                                Text("Cancel")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isCancelHovered ? Color.primary : Color.primary.opacity(0.85))
                            }
                        }
                        .frame(height: 32)
                        .scaleEffect(isCancelHovered ? 1.03 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isCancelHovered)
                        .contentShape(buttonShape)
                    }
                    .buttonStyle(GlassPressFeedbackButtonStyle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            cancelHoverLocation = loc
                            if !isCancelHovered {
                                withAnimation(.easeOut(duration: 0.12)) { isCancelHovered = true }
                            }
                        case .ended:
                            withAnimation(.easeOut(duration: 0.18)) {
                                isCancelHovered = false
                                cancelHoverLocation = .zero
                            }
                        }
                    }

                    // Confirm Disconnect Button with Vibrant Crimson Glow
                    Button(action: onConfirm) {
                        GeometryReader { geo in
                            let size = geo.size
                            let center = confirmHoverLocation == .zero
                                ? CGPoint(x: size.width / 2, y: size.height / 2)
                                : confirmHoverLocation

                            ZStack {
                                // Background coral/red gradient
                                buttonShape
                                    .fill(
                                        LinearGradient(
                                            colors: isConfirmHovered
                                                ? [
                                                    Color(red: 0.98, green: 0.30, blue: 0.30),
                                                    Color(red: 0.86, green: 0.18, blue: 0.18)
                                                  ]
                                                : [
                                                    Color(red: 0.88, green: 0.24, blue: 0.24).opacity(0.35),
                                                    Color(red: 0.75, green: 0.18, blue: 0.18).opacity(0.25)
                                                  ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )

                                // Specular highlight following cursor
                                if isConfirmHovered {
                                    RadialGradient(
                                        colors: [
                                            Color.white.opacity(0.42),
                                            Color.white.opacity(0.12),
                                            .clear
                                        ],
                                        center: UnitPoint(
                                            x: max(0, min(1, center.x / max(size.width, 1))),
                                            y: max(0, min(1, center.y / max(size.height, 1)))
                                        ),
                                        startRadius: 0,
                                        endRadius: max(size.width, size.height) * 0.75
                                    )
                                    .clipShape(buttonShape)
                                }

                                buttonShape
                                    .strokeBorder(
                                        isConfirmHovered
                                            ? Color.white.opacity(0.35)
                                            : Color(red: 1.0, green: 0.40, blue: 0.40).opacity(0.40),
                                        lineWidth: 1
                                    )

                                Text("Disconnect")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(
                                        isConfirmHovered ? Color.white : Color(red: 1.0, green: 0.40, blue: 0.40)
                                    )
                            }
                        }
                        .frame(height: 32)
                        .scaleEffect(isConfirmHovered ? 1.03 : 1.0)
                        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isConfirmHovered)
                        .contentShape(buttonShape)
                    }
                    .buttonStyle(GlassPressFeedbackButtonStyle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            confirmHoverLocation = loc
                            if !isConfirmHovered {
                                withAnimation(.easeOut(duration: 0.12)) { isConfirmHovered = true }
                            }
                        case .ended:
                            withAnimation(.easeOut(duration: 0.18)) {
                                isConfirmHovered = false
                                confirmHoverLocation = .zero
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 250)
        .clipShape(popoverShape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                containerHoverLocation = loc
                if !isContainerHovered {
                    withAnimation(.easeOut(duration: 0.15)) { isContainerHovered = true }
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.22)) {
                    isContainerHovered = false
                    containerHoverLocation = .zero
                }
            }
        }
    }
}

private struct ANCCardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Noise Control")
                        .font(Typography.sectionHeader)
                    Spacer()
                    Text(selectionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                NoiseControlButtonsView(
                    selection: model.anc,
                    enabled: isConnected,
                    setMode: { model.setANC($0) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isConnected: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var selectionLabel: String {
        guard let anc = model.anc else { return "—" }
        switch anc {
        case .on: return "Noise Cancellation"
        case .transparency: return "Transparency"
        case .off: return "Off"
        }
    }
}

/// Innovative Liquid Glass Battery Refresh Button featuring:
/// - Smooth interactive cursor-following specular sheen
/// - Dynamic 360 spin animation on click with spring recoil
/// - Springy scale & pointer-following gentle nudge
/// - Gradient glass border with subtle ambient glow on hover
private struct BatteryRefreshGlassButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero
    @State private var spinAngle: Double = 0
    @State private var isRefreshing = false

    private let buttonCornerRadius: CGFloat = 9
    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        Button {
            // Trigger 360 spin with energetic spring physics
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) {
                spinAngle += 360
                isRefreshing = true
            }
            action()
            // Reset state subtly after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isRefreshing = false
            }
        } label: {
            GeometryReader { geo in
                let size = geo.size
                let center = hoverLocation == .zero
                    ? CGPoint(x: size.width / 2, y: size.height / 2)
                    : hoverLocation

                // Pointer parallax nudge
                let dx = (center.x - size.width / 2) / max(size.width / 2, 1)
                let dy = (center.y - size.height / 2) / max(size.height / 2, 1)
                let nudgeX = isHovered ? (dx * 0.7) : 0
                let nudgeY = isHovered ? (dy * 0.7) : 0

                ZStack {
                    // Glass backing
                    shape
                        .modifier(GlassSurface(shape: shape))
                        .overlay {
                            shape
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12))
                        }

                    // Liquid specular shine tracking cursor
                    if isHovered {
                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.35 : 0.42),
                                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12),
                                .clear
                            ],
                            center: UnitPoint(
                                x: max(0, min(1, center.x / max(size.width, 1))),
                                y: max(0, min(1, center.y / max(size.height, 1)))
                            ),
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.9
                        )
                        .clipShape(shape)
                        .transition(.opacity.animation(.easeInOut(duration: 0.14)))
                    }

                    // Frosted edge highlight stroke
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.38 : (colorScheme == .dark ? 0.16 : 0.20)),
                                    Color.white.opacity(isHovered ? 0.14 : 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    // Button content
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(spinAngle))
                            .foregroundStyle(isRefreshing ? Color.accentColor : (isHovered ? Color.primary : Color.secondary))

                        Text("Refresh")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                    }
                    .offset(x: nudgeX, y: nudgeY)
                }
            }
            .frame(width: 78, height: 26)
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isHovered)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: hoverLocation)
            .contentShape(shape)
        }
        .buttonStyle(GlassPressFeedbackButtonStyle())
        .help("Refresh battery status")
        .accessibilityLabel("Refresh battery")
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
                if !isHovered {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.80)) {
                        isHovered = true
                    }
                }
            case .ended:
                withAnimation(.spring(response: 0.20, dampingFraction: 0.82)) {
                    isHovered = false
                    hoverLocation = .zero
                }
            }
        }
    }
}


private struct BatteryCardView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var isQuitHovered: Bool = false
    var quitHoverLocation: CGPoint = .zero
    var quitSize: CGSize = .zero

    private let cardShape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    /// Computes proximity factor (0.0 to 1.0) where 1.0 means cursor is right at the top edge
    /// of the Quit button (closest to the Battery section), and 0.0 is at the bottom of Quit.
    private var proximityFactor: Double {
        guard isQuitHovered, quitSize.height > 0 else { return 0.0 }
        let normalizedY = max(0.0, min(1.0, Double(quitHoverLocation.y / quitSize.height)))
        // Invert Y so top edge (closest to battery) is 1.0, bottom edge is 0.0
        let rawCloseness = 1.0 - normalizedY
        // Smooth non-linear curve to feel natural and responsive
        return 0.35 + 0.65 * pow(rawCloseness, 1.2)
    }

    /// Normalized horizontal alignment (0.0 to 1.0) corresponding to the cursor's X position in the Quit button
    private var normalizedX: Double {
        guard quitSize.width > 0 else { return 0.5 }
        return max(0.0, min(1.0, Double(quitHoverLocation.x / quitSize.width)))
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Battery")
                        .font(Typography.sectionHeader)
                    Spacer()
                    BatteryRefreshGlassButton(
                        action: { model.refreshBattery() }
                    )
                }

                HStack(spacing: 10) {
                    MetricPill(metric: .total, title: "Total", value: model.displayBattery?.totalWeightedPercent.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                    MetricPill(metric: .left, title: "L", value: model.battery?.left.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                    MetricPill(metric: .right, title: "R", value: model.battery?.right.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                    MetricPill(metric: .case, title: "Case", value: model.displayBattery?.case.map { "\($0)%" } ?? "--")
                        .frame(maxWidth: .infinity)
                }

                if let ts = model.battery?.lastUpdated {
                    Text("Updated \(ts.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            // Radial edge highlight along the bottom stroke that tracks cursor X position
            // and brightens as cursor nears the top edge of Quit
            if isQuitHovered {
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let factor = proximityFactor
                    let strokeIntensity = (colorScheme == .dark ? 0.90 : 0.75) * factor

                    cardShape
                        .stroke(
                            AngularGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color(red: 0.98, green: 0.35, blue: 0.35).opacity(strokeIntensity), location: 0.5),
                                    .init(color: .clear, location: 1.0)
                                ],
                                center: .bottom,
                                startAngle: .degrees(0),
                                endAngle: .degrees(180)
                            ),
                            lineWidth: 1
                        )
                        .mask {
                            // Focus stroke along the bottom edge where the radial leak touches
                            RadialGradient(
                                colors: [
                                    Color.white,
                                    Color.white.opacity(0.8),
                                    Color.white.opacity(0.2),
                                    .clear
                                ],
                                center: UnitPoint(x: normalizedX, y: 1.0),
                                startRadius: 0,
                                endRadius: max(w * 0.45, 120)
                            )
                        }
                }
                .transition(.opacity)
            }
        }
        .background {
            if isQuitHovered {
                // Radial ambient light bleed: origin tracks cursor X along bottom edge,
                // and intensity scales up smoothly as mouse gets closer to the battery section
                GeometryReader { geo in
                    let w = max(geo.size.width, 1)
                    let factor = proximityFactor
                    let peakOpacity = (colorScheme == .dark ? 0.22 : 0.16) * factor
                    let midOpacity = peakOpacity * 0.45

                    RadialGradient(
                        colors: [
                            Color(red: 0.98, green: 0.30, blue: 0.30).opacity(peakOpacity),
                            Color(red: 0.98, green: 0.35, blue: 0.35).opacity(midOpacity),
                            .clear
                        ],
                        center: UnitPoint(x: normalizedX, y: 1.05),
                        startRadius: 0,
                        endRadius: max(w * 0.55, 160)
                    )
                    .clipShape(cardShape)
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isQuitHovered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuitSectionCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @Binding var isHovered: Bool
    @Binding var hoverLocation: CGPoint
    @Binding var cardSize: CGSize

    private let buttonCornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)

        VStack {
            Button {
                model.quit()
            } label: {
                VStack(spacing: 5) {
                    HStack(spacing: 9) {
                        Image(systemName: "power")
                            .font(.system(size: 17, weight: .medium))
                        Text("Quit completely")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(isHovered ? Color.white : Color.primary)

                    if isHovered {
                        Text("All features and background connection will be disabled.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, isHovered ? 14 : 13)
                .background {
                    GeometryReader { geo in
                        let size = geo.size
                        let center = hoverLocation == .zero
                            ? CGPoint(x: size.width / 2, y: size.height / 2)
                            : hoverLocation

                        ZStack {
                            // Unhovered button: dark tinted card matching screenshot
                            shape
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.09))

                            // Hovered button: vivid coral-red matching screenshot
                            if isHovered {
                                shape
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.98, green: 0.35, blue: 0.35),
                                                Color(red: 0.90, green: 0.25, blue: 0.25)
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .transition(.opacity)

                                // Specular radial highlight following mouse
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(0.38),
                                        Color.white.opacity(0.12),
                                        .clear
                                    ],
                                    center: UnitPoint(
                                        x: max(0, min(1, center.x / max(size.width, 1))),
                                        y: max(0, min(1, center.y / max(size.height, 1)))
                                    ),
                                    startRadius: 0,
                                    endRadius: max(size.width, size.height) * 0.75
                                )
                                .clipShape(shape)
                                .transition(.opacity)
                            }

                            // Clean outer border stroke
                            shape
                                .strokeBorder(
                                    isHovered
                                        ? Color.white.opacity(0.24)
                                        : Color.white.opacity(colorScheme == .dark ? 0.12 : 0.16),
                                    lineWidth: 1
                                )
                        }
                        .onAppear {
                            cardSize = size
                        }
                        .onChange(of: size) { _, newSize in
                            cardSize = newSize
                        }
                    }
                }
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    if !isHovered {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            isHovered = true
                        }
                    }
                case .ended:
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        isHovered = false
                        hoverLocation = .zero
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}


private struct MetricPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let metric: IconKit.BatteryMetric
    let title: String
    let value: String

    @State private var isHovered = false
    @State private var hoverLocation: CGPoint = .zero

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .center, spacing: 6) {
            IconKit.batteryIcon(for: metric)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 22, height: 22)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background {
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    // Base button fill elevated subtly above the card
                    shape
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.08))

                    // Hover glow: specular radial sheen following cursor
                    if isHovered {
                        let center = hoverLocation == .zero
                            ? CGPoint(x: size.width / 2, y: size.height / 2)
                            : hoverLocation

                        RadialGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.22 : 0.30),
                                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.12),
                                .clear
                            ],
                            center: UnitPoint(
                                x: center.x / max(size.width, 1),
                                y: center.y / max(size.height, 1)
                            ),
                            startRadius: 0,
                            endRadius: max(size.width, size.height) * 0.75
                        )
                        .clipShape(shape)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    }

                    // Delicate perimeter stroke
                    shape
                        .strokeBorder(
                            Color.white.opacity(isHovered ? 0.22 : 0.08),
                            lineWidth: 1
                        )
                }
            }
        }
        .contentShape(shape)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = true
                    hoverLocation = location
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovered = false
                    hoverLocation = .zero
                }
            }
        }
    }
}

