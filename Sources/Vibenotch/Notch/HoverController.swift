import AppKit

@MainActor
protocol HoverControllerDelegate: AnyObject {
    func hoverControllerDidEnter(_ controller: HoverController)
    func hoverControllerDidExit(_ controller: HoverController)
    func hoverController(_ controller: HoverController, containsExpandedPoint point: NSPoint) -> Bool
}

@MainActor
final class HoverController: NSObject {
    private weak var delegate: HoverControllerDelegate?
    private var trackingPanel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var notchRect = NSRect.zero   // the physical cutout (tracking panel frame)
    private var hitRect = NSRect.zero     // widened trigger zone (covers the visible peek + margin)
    private var pointerIsInside = false
    private var enterDelivered = false
    private var enterTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var lastGlobalHitTestTime: TimeInterval = 0
    private var isPinned = false

    init(delegate: HoverControllerDelegate) {
        self.delegate = delegate
        super.init()
        installEventMonitors()
    }

    func pin(to screen: NSScreen) {
        notchRect = Self.notchRect(on: screen)
        // Widen the trigger zone so hovering the VISIBLE peek beside the cutout also expands.
        let sideMargin: CGFloat = 150
        let bottomExtra: CGFloat = 16
        hitRect = NotchGeometry.hitRect(
            from: notchRect,
            sideMargin: sideMargin,
            bottomExtra: bottomExtra
        )
        isPinned = true

        let trackingView = NotchTrackingView(frame: NSRect(origin: .zero, size: notchRect.size))
        trackingView.delegate = self

        let panel: NSPanel
        if let trackingPanel {
            panel = trackingPanel
        } else {
            panel = HoverTrackingPanel(
                contentRect: notchRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.acceptsMouseMovedEvents = true
            self.trackingPanel = panel
        }

        panel.contentView = trackingView
        panel.setFrame(notchRect, display: true)
        panel.orderFrontRegardless()
        updatePointerState(at: NSEvent.mouseLocation)

        HoverDiag.log("PIN notchRect=\(notchRect) hitRect=\(hitRect) screenFrame=\(screen.frame) monitors=\(globalMonitor != nil)/\(localMonitor != nil)")
    }

    func suspend() {
        isPinned = false
        pointerIsInside = false
        enterDelivered = false
        enterTask?.cancel()
        exitTask?.cancel()
        trackingPanel?.orderOut(nil)
    }

    private func installEventMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseMove(at: NSEvent.mouseLocation)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updatePointerState(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func handleGlobalMouseMove(at point: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGlobalHitTestTime >= (1.0 / 30.0) else { return }
        lastGlobalHitTestTime = now
        updatePointerState(at: point)
    }

    private func updatePointerState(at point: NSPoint) {
        guard isPinned else { return }
        let insideNotch = hitRect.contains(point)
        let insideExpandedPanel = delegate?.hoverController(
            self,
            containsExpandedPoint: point
        ) ?? false
        setPointerInside(insideNotch || insideExpandedPanel)
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerIsInside else { return }
        pointerIsInside = inside

        if inside {
            exitTask?.cancel()
            guard !enterDelivered else { return }

            enterTask?.cancel()
            enterTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard let self, self.pointerIsInside, !self.enterDelivered else { return }
                self.enterDelivered = true
                HoverDiag.log("ENTER delivered -> expand()")
                self.delegate?.hoverControllerDidEnter(self)
            }
        } else {
            enterTask?.cancel()
            guard enterDelivered else { return }

            exitTask?.cancel()
            exitTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                guard let self, !self.pointerIsInside, self.enterDelivered else { return }
                self.enterDelivered = false
                HoverDiag.log("EXIT delivered -> collapse()")
                self.delegate?.hoverControllerDidExit(self)
            }
        }
    }

    private static func notchRect(on screen: NSScreen) -> NSRect {
        if let notchRect = NotchGeometry.notchRect(
            auxLeftMaxX: screen.auxiliaryTopLeftArea?.maxX,
            auxRightMinX: screen.auxiliaryTopRightArea?.minX,
            frameMaxY: screen.frame.maxY,
            safeTop: screen.safeAreaInsets.top
        ) {
            return notchRect
        }

        let fallbackWidth: CGFloat = 300
        return NotchGeometry.fallbackRect(
            frameMidX: screen.frame.midX,
            frameMaxY: screen.frame.maxY,
            visibleMaxY: screen.visibleFrame.maxY,
            width: fallbackWidth
        )
    }
}

extension HoverController: NotchTrackingViewDelegate {
    fileprivate func trackingViewMouseEntered(_ view: NotchTrackingView) {
        setPointerInside(true)
    }

    fileprivate func trackingViewMouseExited(_ view: NotchTrackingView) {
        updatePointerState(at: NSEvent.mouseLocation)
    }
}

@MainActor
private protocol NotchTrackingViewDelegate: AnyObject {
    func trackingViewMouseEntered(_ view: NotchTrackingView)
    func trackingViewMouseExited(_ view: NotchTrackingView)
}

@MainActor
private final class NotchTrackingView: NSView {
    weak var delegate: NotchTrackingViewDelegate?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        delegate?.trackingViewMouseEntered(self)
    }

    override func mouseExited(with event: NSEvent) {
        delegate?.trackingViewMouseExited(self)
    }
}

private final class HoverTrackingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// Debug logger for hover diagnostics + automated evals. Silent unless NOTCHHUD_DEBUG=1.
enum HoverDiag {
    static let enabled = ProcessInfo.processInfo.environment["NOTCHHUD_DEBUG"] == "1"
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vibenotch/hover.log")
    static func log(_ msg: String) {
        guard enabled else { return }
        let line = "\(Date()) \(msg)\n"
        NSLog("[HoverDiag] \(msg)")
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }
}
