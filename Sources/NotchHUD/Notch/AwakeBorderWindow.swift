import AppKit
import Observation
import QuartzCore

@MainActor
final class AwakeBorderWindow {
    private let engine: KeepAwakeEngine
    private let panel: NSPanel
    private let borderView = AwakeBorderView(frame: .zero)
    private var isObserving = false
    private var lastActive = false
    private var pulseTask: Task<Void, Never>?

    init(engine: KeepAwakeEngine) {
        self.engine = engine
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = borderView
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderView.autoresizingMask = [.width, .height]
        lastActive = engine.isActive
        updateVisibility(active: lastActive, pulse: false)
        observeActivity()
    }

    func pin(to screen: NSScreen) {
        let notchRect = NotchGeometry.notchRect(
            auxLeftMaxX: screen.auxiliaryTopLeftArea?.maxX,
            auxRightMinX: screen.auxiliaryTopRightArea?.minX,
            frameMaxY: screen.frame.maxY,
            safeTop: screen.safeAreaInsets.top
        ) ?? NotchGeometry.fallbackRect(
            frameMidX: screen.frame.midX,
            frameMaxY: screen.frame.maxY,
            visibleMaxY: screen.visibleFrame.maxY,
            width: 300
        )
        updateFrame(notchRect, animated: false)
    }

    func updateFrame(_ contentRect: CGRect, animated: Bool) {
        let frame = NotchGeometry.borderRect(from: contentRect)
        borderView.needsDisplay = true

        guard animated, panel.isVisible, panel.frame != frame else {
            panel.setFrame(frame, display: panel.isVisible)
            borderView.frame = NSRect(origin: .zero, size: frame.size)
            updateVisibility(active: engine.isActive, pulse: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    func shutdown() {
        isObserving = false
        pulseTask?.cancel()
        panel.orderOut(nil)
        panel.close()
    }

    private func observeActivity() {
        isObserving = true
        withObservationTracking {
            _ = engine.isActive
        } onChange: { [weak self] in
            // KeepAwakeEngine is main-actor isolated, so its change callback
            // arrives on the main actor and can safely re-arm synchronously.
            let didRearm = MainActor.assumeIsolated {
                guard let self, self.isObserving else { return false }
                self.observeActivity()
                return true
            }
            guard didRearm else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.applyCurrentActivity()
            }
        }
    }

    private func applyCurrentActivity() {
        let active = engine.isActive
        updateVisibility(active: active, pulse: active && !lastActive)
        lastActive = active
    }

    private func updateVisibility(active: Bool, pulse: Bool) {
        pulseTask?.cancel()
        guard active, panel.frame.width > 0 else {
            panel.orderOut(nil)
            return
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard pulse else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0.55
        }
        pulseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.engine.isActive else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.75
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.panel.animator().alphaValue = 0.9
            }
        }
    }
}

private final class AwakeBorderView: NSView {
    override var isFlipped: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(NotchGeometry.borderPath(in: bounds, cornerRadius: 11, strokeWidth: 2))
        context.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.strokePath()
    }
}
