import SwiftUI
import AppKit
import BudsCore

enum IconKit {
    static let staticMenuBarNSImage: NSImage = {
        let img = NSImage(systemSymbolName: "airpods", accessibilityDescription: nil) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let configured = img.withSymbolConfiguration(config) ?? img
        configured.isTemplate = true
        return configured
    }()

    static let playbackAnimationNSImages: [NSImage] = {
        let barHeights: [[CGFloat]] = [
            [2.5, 8.5, 4.5],
            [5.5, 3.5, 7.5],
            [8.5, 9.5, 3.5],
            [4.5, 6.5, 8.5],
            [7.5, 2.5, 5.5],
            [3.5, 7.5, 2.5]
        ]
        let opacities: [CGFloat] = [1.0, 0.88, 0.72, 0.85, 1.0, 0.92]

        let symbolImg = NSImage(systemSymbolName: "airpods", accessibilityDescription: nil) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let configuredSymbol = symbolImg.withSymbolConfiguration(config) ?? symbolImg

        let symbolSize = configuredSymbol.size
        let eqWidth: CGFloat = 8.5
        let spacing: CGFloat = 3.5
        let totalWidth = symbolSize.width + spacing + eqWidth
        let totalHeight = max(symbolSize.height, 15.0)

        return (0..<barHeights.count).map { idx in
            let heights = barHeights[idx]
            let opacity = opacities[idx]

            let finalImage = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
                let symbolRect = NSRect(
                    x: 0,
                    y: (totalHeight - symbolSize.height) / 2.0,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                configuredSymbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: opacity)

                let startX = symbolSize.width + spacing
                let barWidth: CGFloat = 1.8
                let barSpacing: CGFloat = 1.4
                let cornerRadius: CGFloat = 0.8

                NSColor.black.setFill()
                for i in 0..<3 {
                    let h = heights[i]
                    let x = startX + CGFloat(i) * (barWidth + barSpacing)
                    let y = (totalHeight - 10.0) / 2.0
                    let barRect = NSRect(x: x, y: y, width: barWidth, height: h)
                    let path = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
                    path.fill()
                }
                return true
            }
            finalImage.isTemplate = true
            return finalImage
        }
    }()

    static func menuBarMark() -> Image {
        Image(nsImage: staticMenuBarNSImage)
    }

    static func ancIcon(for mode: ANCMode?, connected: Bool) -> Image {
        let name: String? = {
            switch mode {
            case .some(.on): return "anc_on"
            case .some(.transparency): return "anc_trans"
            case .some(.off): return "anc_off"
            case .none:
                // Unknown/unsynced state: don't lie by showing "off".
                return nil
            }
        }()

        if let name, let img = loadTemplateImage(named: name) {
            return Image(nsImage: img)
        }

        // SF Symbols-first: neutral, Apple-like.
        if !connected {
            return Image(systemName: "ear.trianglebadge.exclamationmark")
        }
        switch mode {
        case .some(.on):
            return Image(systemName: "waveform.badge.minus")
        case .some(.transparency):
            return Image(systemName: "ear.and.waveform")
        case .some(.off):
            return Image(systemName: "circle")
        case .none:
            return menuBarMark()
        }
    }

    static func batteryIcon(for metric: BatteryMetric) -> Image {
        switch metric {
        case .total: return Image(systemName: "battery.100percent")
        case .left: return Image(systemName: "earbud.left")
        case .right: return Image(systemName: "earbud.right")
        case .case: return Image(systemName: "earbuds.case")
        }
    }

    enum BatteryMetric: Sendable {
        case total
        case left
        case right
        case `case`
    }

    private static func loadTemplateImage(named base: String) -> NSImage? {
        // Expect icons under Resources/Icons as anc_on.(pdf|png) etc.
        let exts = ["pdf", "png"]
        for ext in exts {
            if let url = Bundle.module.url(forResource: base, withExtension: ext, subdirectory: "Icons"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}
