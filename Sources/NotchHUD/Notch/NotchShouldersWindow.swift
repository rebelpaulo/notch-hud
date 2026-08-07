import AppKit

/// While the panel is expanded the HUD should read as one solid black shape,
/// but the notch band beside the physical cutout still shows the desktop.
/// This pass-through window paints those two "shoulders" black. It never
/// overlaps the compact pill (it draws only left/right of it), so it can't
/// cover the sprites regardless of window ordering.
@MainActor
final class NotchShouldersWindow {
    private let panel: NSPanel
    private let shouldersView = NotchShouldersView(frame: .zero)

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = shouldersView
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        shouldersView.autoresizingMask = [.width, .height]
    }

    /// - Parameters:
    ///   - bandRect: the full notch-band strip to cover (screen coordinates).
    ///   - pillRect: the compact pill, carved out of the fill.
    func show(bandRect: CGRect, pillRect: CGRect) {
        guard bandRect.width > 0, bandRect.height > 0 else {
            hide()
            return
        }
        panel.setFrame(bandRect, display: true)
        shouldersView.gap = pillRect.offsetBy(dx: -bandRect.minX, dy: -bandRect.minY)
        shouldersView.needsDisplay = true
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func shutdown() {
        panel.orderOut(nil)
        panel.close()
    }
}

private final class NotchShouldersView: NSView {
    var gap: CGRect = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.078, green: 0.078, blue: 0.086, alpha: 1).setFill()

        let left = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, gap.minX - bounds.minX),
            height: bounds.height
        )
        let right = CGRect(
            x: max(bounds.minX, gap.maxX),
            y: bounds.minY,
            width: max(0, bounds.maxX - max(bounds.minX, gap.maxX)),
            height: bounds.height
        )
        left.intersection(bounds).fill()
        right.intersection(bounds).fill()
    }
}
