import AppKit
import OSLog

/// Monitors global and local mouse events to detect two-finger taps or right-clicks
/// directly on the Buds menu bar icon.
///
/// In macOS SwiftUI, `MenuBarExtra` rasterizes its label view (`MenuBarLabelView`) into a static
/// or off-screen image for the status item rather than hosting a live, interactive `NSView` in the
/// system status bar window. As a result, standard SwiftUI gestures and `NSViewRepresentable`
/// view-lifecycle callbacks (`viewDidMoveToWindow`) are never called on the menu bar button.
///
/// This monitor circumvents that limitation by installing low-overhead AppKit mouse monitors:
/// 1. `localMonitor`: Catches `.rightMouseDown` events when the Buds app itself is active or the popover is open.
/// 2. `globalMonitor`: Catches `.rightMouseDown` events when another application (Finder, Safari, etc.) is active.
///
/// When a right-click / two-finger click is received, the monitor inspects `NSApplication.shared.windows`
/// to find the visible `NSStatusBarWindow` assigned to Buds. If the click occurred within its screen bounds,
/// the action callback is triggered with an 0.8s debounce to prevent duplicate execution.
@MainActor
final class MenuBarRightClickMonitor {
    private nonisolated(unsafe) var localMonitor: Any?
    private nonisolated(unsafe) var globalMonitor: Any?
    private let onRightClick: () -> Void
    private var lastTriggerAt: Date = .distantPast
    private let logger = Logger(subsystem: "local.nordbuds", category: "MenuBarRightClick")

    init(onRightClick: @escaping () -> Void) {
        self.onRightClick = onRightClick
        setupMonitors()
    }

    private func trigger() {
        let now = Date()
        guard now.timeIntervalSince(lastTriggerAt) > 0.8 else { return }
        lastTriggerAt = now
        logger.info("Two-finger / right-click detected on menu bar icon: triggering disconnect")
        onRightClick()
    }

    /// Checks if a given screen point or event window belongs to Buds's menu bar status item.
    private func isClickOnStatusItem(at screenPoint: NSPoint, window: NSWindow?) -> Bool {
        let windows = NSApplication.shared.windows
        for win in windows {
            let className = String(describing: type(of: win))
            guard className.contains("StatusBar") else { continue }
            // Must be a visible status item window on screen (positive Y origin)
            guard win.frame.origin.y > 0, win.frame.size.width > 0, win.frame.size.height > 0 else { continue }

            if let window, win == window || win.windowNumber == window.windowNumber {
                return true
            }

            if win.frame.contains(screenPoint) {
                return true
            }
        }
        return false
    }

    private func setupMonitors() {
        // Local monitor: handles clicks when Buds.app is focused/active
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let point = NSEvent.mouseLocation
            if self.isClickOnStatusItem(at: point, window: event.window) {
                DispatchQueue.main.async {
                    self.trigger()
                }
                return nil // Consume event to prevent unintended menu popup
            }
            return event
        }

        // Global monitor: handles clicks when another application is focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if self.isClickOnStatusItem(at: point, window: nil) {
                DispatchQueue.main.async {
                    self.trigger()
                }
            }
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}
