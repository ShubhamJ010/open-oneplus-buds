import SwiftUI
import BudsCore
import AppKit

struct PopoverRootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                HeaderCardView()
                ANCCardView()
                BatteryCardView()
                FooterView()
            }
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

                    Button {
                        model.reconnect()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .rotationEffect(.degrees(isReconnecting ? 360 : 0))
                            .animation(isReconnecting ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isReconnecting)
                    }
                    .buttonStyle(.glass)
                    .help("Reconnect")
                    .accessibilityLabel("Reconnect")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FooterView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Spacer()
            Button("Quit") { model.quit() }
                .buttonStyle(.glass)
        }
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

