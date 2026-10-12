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
                        Button {
                            model.reconnect()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .semibold))
                                .rotationEffect(.degrees(isReconnecting ? 360 : 0))
                                .animation(isReconnecting ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isReconnecting)
                        }
                        .buttonStyle(.glass)
                        .help("Reconnect / Snatch Connection")
                        .accessibilityLabel("Reconnect")

                        if isConnected {
                            Button {
                                showDisconnectConfirm.toggle()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.glass)
                            .help("Disconnect")
                            .accessibilityLabel("Disconnect")
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
                    StatusChip(text: notConnectedText, kind: .failure)
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
        !isConnected && model.lastError != nil
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

private struct DisconnectConfirmPopoverView: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Disconnect this device?")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onConfirm) {
                    Text("Confirm")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.red.opacity(0.2))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 240)
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
                    Button {
                        model.refreshBattery()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.glass)
                    .controlSize(.small)
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
                            .padding(.horizontal, 16)
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

