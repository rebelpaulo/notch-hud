import AppKit
import DynamicNotchKit
import SwiftUI

@MainActor
final class NotchWindowManager {
    enum ExpansionReason: String {
        case hover
        case pending
        case manual
    }

    private typealias NotchedHUD = DynamicNotch<EmptyView, NotchPeekView, NotchPeekTrailingView>
    private typealias FloatingPeek = DynamicNotch<NotchFloatingPeekView, EmptyView, EmptyView>

    private let environment: AppEnvironment
    private let store: SessionStore
    private let pendingStore: PendingStore
    private let focusDispatcher: FocusDispatcher
    private let updateStore: UpdateStore
    private let updateLauncher: TerminalUpdateLauncher
    private let keepAwakeEngine: KeepAwakeEngine
    /// Injected, not owned: the remote bridge needs the same one. Two stores
    /// meant two polls of the same endpoints and a panel showing the progress
    /// of whichever one was not doing the work.
    private let usageStore: UsageStore
    private let sleepGuardController: SleepGuardController
    private let decisionWriter: ApprovalDecisionWriter
    private var hoverController: HoverController?
    private var awakeBorderWindow: AwakeBorderWindow?
    private var shouldersWindow: NotchShouldersWindow?
    private var selectedScreen: NSScreen?
    private var notchedHUD: NotchedHUD?
    private var floatingPeek: FloatingPeek?
    private var interactivePanel: InteractiveNotchPanel?
    private var panelHostingView: NSHostingView<NotchPanelView>?
    private var settingsWindowController: SettingsWindowController?
    private var transitionTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var globalMouseDownMonitor: Any?
    private var localEventMonitor: Any?
    private var transitionGeneration = 0
    private var renderedPanelSize: CGSize?
    private var compactLeadingSize = CGSize.zero
    private var compactTrailingSize = CGSize.zero
    // Measured against the rendered pill (screenshot pixel analysis): 14 pt
    // overshot the black shape by ~8 pt per side.
    private let compactContentSideInset: CGFloat = 6
    private var pendingAutoExpandActive = false
    private(set) var isExpanded = false
    private(set) var expansionReason: ExpansionReason?

    init(
        environment: AppEnvironment,
        store: SessionStore,
        pendingStore: PendingStore,
        focusDispatcher: FocusDispatcher,
        updateStore: UpdateStore,
        updateLauncher: TerminalUpdateLauncher = TerminalUpdateLauncher(),
        keepAwakeEngine: KeepAwakeEngine,
        usageStore: UsageStore,
        sleepGuardController: SleepGuardController
    ) {
        self.environment = environment
        self.store = store
        self.pendingStore = pendingStore
        self.focusDispatcher = focusDispatcher
        self.updateStore = updateStore
        self.updateLauncher = updateLauncher
        self.keepAwakeEngine = keepAwakeEngine
        self.usageStore = usageStore
        self.sleepGuardController = sleepGuardController
        decisionWriter = ApprovalDecisionWriter(
            decisionsURL: environment.decisionsURL,
            sessionAllowURL: environment.sessionAllowURL
        )
    }

    func boot() {
        _ = environment.spoolURL
        _ = environment.pendingURL

        let hoverController = HoverController(delegate: self)
        self.hoverController = hoverController
        awakeBorderWindow = AwakeBorderWindow(engine: keepAwakeEngine)
        shouldersWindow = NotchShouldersWindow()
        installInteractionMonitors()
        repinToBuiltInScreen()
    }

    func shutdown() {
        hoverController?.suspend()
        awakeBorderWindow?.shutdown()
        awakeBorderWindow = nil
        shouldersWindow?.shutdown()
        shouldersWindow = nil
        transitionTask?.cancel()
        watchdogTask?.cancel()
        removeInteractionMonitors()
        removeInteractivePanel()
        settingsWindowController?.closeSettings()
        settingsWindowController = nil
    }

    func repinToBuiltInScreen() {
        guard let screen = preferredScreen() else {
            NSLog("Vibenotch could not find a screen to pin to.")
            return
        }

        hoverController?.suspend()
        selectedScreen = screen
        compactLeadingSize = .zero
        compactTrailingSize = .zero
        awakeBorderWindow?.pin(to: screen)
        resetExpansionState(reason: .manual)
        renderedPanelSize = nil

        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            guard let self else { return }
            await self.hideEveryNotch()
            guard self.transitionGeneration == generation else { return }

            self.clearNotches()
            if screen.safeAreaInsets.top > 0 {
                await self.installNotchedHUD(on: screen, generation: generation)
            } else {
                NSLog("Vibenotch found no notched display; using a top-center floating pill.")
                await self.installFloatingHUD(on: screen, generation: generation)
            }

            guard self.transitionGeneration == generation, !self.isExpanded else { return }
            self.installInteractivePanel()
            self.hoverController?.pin(to: screen)
            self.awakeBorderWindow?.pin(to: screen)
            if self.pendingStore.hasPending {
                self.pendingAutoExpandActive = true
                self.expand(reason: .pending)
            } else {
                self.pendingAutoExpandActive = false
            }
        }
    }

    func applyPendingApprovals(_ approvals: [PendingApproval]) {
        let previouslyHadPending = pendingStore.hasPending
        pendingStore.apply(approvals)
        store.markPendingApprovals(sessionIDs: Set(approvals.map(\.sessionId)))
        handlePendingTransition(previouslyHadPending: previouslyHadPending)
    }

    private func approvalDidResolve(sessionID: String) {
        let previouslyHadPending = pendingStore.hasPending
        pendingStore.dismiss(sessionID: sessionID)
        store.markPendingApprovals(sessionIDs: Set(pendingStore.approvals.map(\.sessionId)))
        handlePendingTransition(previouslyHadPending: previouslyHadPending)
    }

    private func dismissSession(sessionID: String) {
        guard !sessionID.isEmpty,
              !sessionID.contains("/"),
              sessionID != ".",
              sessionID != ".."
        else { return }

        // Only drop the card once the file is really gone — otherwise the
        // next spool rescan would resurrect it.
        let fileURL = environment.spoolURL.appendingPathComponent("\(sessionID).json", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            store.apply(store.sessionsWithoutPendingOverlay.filter { $0.id != sessionID })
        } catch {
            NSLog("Vibenotch could not dismiss session %@: %@", sessionID, error.localizedDescription)
        }
    }

    private func handlePendingTransition(previouslyHadPending: Bool) {
        if pendingStore.hasPending {
            pendingAutoExpandActive = true
            expand(reason: .pending)
            return
        }

        guard previouslyHadPending || pendingAutoExpandActive else { return }
        pendingAutoExpandActive = false
        if !containsExpandedContent(at: NSEvent.mouseLocation) {
            collapse(reason: .pending)
        }
    }

    func expand(reason: ExpansionReason) {
        HoverDiag.log(
            "expand(reason: \(reason.rawValue)) isExpanded=\(isExpanded) "
                + "selectedScreen=\(selectedScreen != nil) notchedHUD=\(notchedHUD != nil)"
        )
        guard !isExpanded, let screen = selectedScreen else { return }
        guard notchedHUD != nil || floatingPeek != nil else { return }

        isExpanded = true
        expansionReason = reason
        startWatchdog()

        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        showInteractivePanel()

        if let notchedHUD {
            configurePassThroughWindow(notchedHUD.windowController?.window)
            transitionTask = Task { [weak self, weak notchedHUD] in
                guard let self, let notchedHUD else { return }
                await notchedHUD.expand(on: screen)
                guard self.transitionGeneration == generation, self.isExpanded else { return }
                self.configurePassThroughWindow(notchedHUD.windowController?.window)
                self.showInteractivePanel()
            }
            return
        }

        guard let floatingPeek else { return }
        configurePassThroughWindow(floatingPeek.windowController?.window)
        transitionTask = Task { [weak self, weak floatingPeek] in
            guard let self, let floatingPeek else { return }
            await floatingPeek.hide()
            guard self.transitionGeneration == generation, self.isExpanded else { return }
            self.showInteractivePanel()
        }
    }

    func collapse(reason: ExpansionReason) {
        if reason == .hover, pendingAutoExpandActive, pendingStore.hasPending {
            HoverDiag.log("collapse(reason: hover) ignored while a pending card is showing")
            return
        }
        guard isExpanded else { return }

        HoverDiag.log("collapse(reason: \(reason.rawValue))")
        isExpanded = false
        expansionReason = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        interactivePanel?.orderOut(nil)
        updateAwakeBorderFrame(animated: true)

        transitionGeneration += 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        guard let screen = selectedScreen else { return }

        if let notchedHUD {
            configurePassThroughWindow(notchedHUD.windowController?.window)
            transitionTask = Task { [weak self, weak notchedHUD] in
                guard let self, let notchedHUD else { return }
                await notchedHUD.compact(on: screen)
                guard self.transitionGeneration == generation, !self.isExpanded else { return }
                self.configurePassThroughWindow(notchedHUD.windowController?.window)
            }
            return
        }

        guard let floatingPeek else { return }
        transitionTask = Task { [weak self, weak floatingPeek] in
            guard let self, let floatingPeek else { return }
            await floatingPeek.expand(on: screen)
            guard self.transitionGeneration == generation, !self.isExpanded else { return }
            self.configurePassThroughWindow(floatingPeek.windowController?.window)
        }
    }

    func containsExpandedContent(at point: NSPoint) -> Bool {
        guard isExpanded, let panel = interactivePanel, panel.isVisible else { return false }
        return panel.frame.contains(point)
    }

    private func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
    }

    private func installNotchedHUD(on screen: NSScreen, generation: Int) async {
        let store = store
        let pendingStore = pendingStore
        let notch = NotchedHUD(
            hoverBehavior: [],
            style: .notch,
            expanded: { EmptyView() },
            compactLeading: { [weak self] in
                NotchPeekView(
                    store: store,
                    pendingStore: pendingStore,
                    onSizeChange: { [weak self] size in
                        self?.updateCompactLeadingSize(size)
                    }
                )
            },
            compactTrailing: { [weak self] in
                NotchPeekTrailingView(
                    store: store,
                    onSizeChange: { [weak self] size in
                        self?.updateCompactTrailingSize(size)
                    }
                )
            }
        )
        notch.transitionConfiguration.skipIntermediateHides = true
        notchedHUD = notch

        await notch.compact(on: screen)
        guard transitionGeneration == generation, !isExpanded else { return }
        configurePassThroughWindow(notch.windowController?.window)
    }

    private func installFloatingHUD(on screen: NSScreen, generation: Int) async {
        let store = store
        let pendingStore = pendingStore
        let peek = FloatingPeek(
            hoverBehavior: [],
            style: .floating,
            expanded: { NotchFloatingPeekView(store: store, pendingStore: pendingStore) }
        )
        floatingPeek = peek

        await peek.expand(on: screen)
        guard transitionGeneration == generation, !isExpanded else { return }
        configurePassThroughWindow(peek.windowController?.window)
    }

    private func installInteractivePanel() {
        removeInteractivePanel()

        let store = store
        let pendingStore = pendingStore
        let focusDispatcher = focusDispatcher
        let updateStore = updateStore
        let updateLauncher = updateLauncher
        let decisionWriter = decisionWriter
        let keepAwakeEngine = keepAwakeEngine
        let closedLidModeAvailable = sleepGuardController.isInstalled
        let rootView = NotchPanelView(
            store: store,
            pendingStore: pendingStore,
            focusDispatcher: focusDispatcher,
            updateStore: updateStore,
            updateLauncher: updateLauncher,
            decisionWriter: decisionWriter,
            keepAwakeEngine: keepAwakeEngine,
            usageStore: usageStore,
            closedLidModeAvailable: closedLidModeAvailable,
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onApprovalDismiss: { [weak self] sessionID in
                self?.approvalDidResolve(sessionID: sessionID)
            },
            onSessionDismiss: { [weak self] sessionID in
                self?.dismissSession(sessionID: sessionID)
            },
            onSizeChange: { [weak self] size in
                self?.updateRenderedPanelSize(size)
            }
        )
        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]

        let panel = InteractiveNotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.onEscape = { [weak self] in
            self?.collapse(reason: .manual)
        }

        interactivePanel = panel
        panelHostingView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            updateRenderedPanelSize(fittingSize)
        }
    }

    private func openSettings() {
        NSLog("Vibenotch openSettings entered")
        collapse(reason: .manual)
        // Let the SwiftUI Button action finish before ordering a new key window;
        // collapse synchronously orders out the hosting panel that owns the action.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsWindowController == nil {
                self.settingsWindowController = SettingsWindowController(
                    keepAwakeEngine: self.keepAwakeEngine,
                    closedLidModeAvailable: self.sleepGuardController.isInstalled,
                    spoolURL: self.environment.spoolURL,
                    workingStaleSeconds: self.environment.workingStaleSeconds,
                    dropSeconds: self.environment.dropSeconds
                )
                NSLog("Vibenotch openSettings created controller")
            }
            self.settingsWindowController?.show()
            if let window = self.settingsWindowController?.window {
                NSLog(
                    "Vibenotch openSettings after show visible=%d key=%d frame=%@",
                    window.isVisible,
                    window.isKeyWindow,
                    NSStringFromRect(window.frame)
                )
            }
        }
    }

    private func updateCompactLeadingSize(_ size: CGSize) {
        guard compactLeadingSize != size else { return }
        compactLeadingSize = size
        updateAwakeBorderFrame(animated: true)
    }

    private func updateCompactTrailingSize(_ size: CGSize) {
        guard compactTrailingSize != size else { return }
        compactTrailingSize = size
        updateAwakeBorderFrame(animated: true)
    }

    private func updateAwakeBorderFrame(animated: Bool) {
        guard let screen = selectedScreen else { return }
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
        let pillRect = NotchGeometry.compactPillRect(
            from: notchRect,
            leadingSize: compactLeadingSize,
            trailingSize: compactTrailingSize,
            // DynamicNotchKit adds 8 pt beside compact content and another
            // 6 pt for the compact shape's top-corner inset.
            sideInset: compactContentSideInset
        )

        // Expanded: the HUD *is* the panel, so the border has to hug the whole
        // thing (union keeps the notch band joined to the panel below it),
        // otherwise it floats around the old pill while the panel is open.
        let targetRect: CGRect
        if isExpanded, let panel = interactivePanel, panel.isVisible {
            targetRect = pillRect.union(panel.frame)
            // Paint the notch band beside the cutout black so the expanded HUD
            // reads as one shape instead of a pill floating over the desktop.
            let band = CGRect(
                x: targetRect.minX,
                y: pillRect.minY,
                width: targetRect.width,
                height: max(0, targetRect.maxY - pillRect.minY)
            )
            // Carve out only the physical cutout (already black hardware).
            // Carving the whole pill would leave its transparent flanks blue,
            // because the compact content is hidden while expanded.
            shouldersWindow?.show(bandRect: band, pillRect: notchRect)
        } else {
            targetRect = pillRect
            shouldersWindow?.hide()
        }
        awakeBorderWindow?.updateFrame(targetRect, animated: animated)
    }

    private func showInteractivePanel() {
        guard isExpanded, let panel = interactivePanel else { return }

        if renderedPanelSize == nil, let hostingView = panelHostingView {
            hostingView.layoutSubtreeIfNeeded()
            let fittingSize = hostingView.fittingSize
            if fittingSize.width > 0, fittingSize.height > 0 {
                updateRenderedPanelSize(fittingSize)
            }
        }

        guard renderedPanelSize != nil else {
            // Never make an unmeasured (and potentially oversized) panel interactive.
            return
        }
        positionInteractivePanel()
        panel.makeKeyAndOrderFront(nil)
        updateAwakeBorderFrame(animated: true)
    }

    private func updateRenderedPanelSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        // The ceiling is the screen, not a constant. It used to be a flat 560,
        // which silently clipped anything taller — the quota tab asks for far
        // more than a session list, and the cards below the fold simply were
        // not drawn. Leave room for the notch band and a margin so the panel
        // never runs off the bottom of a short display.
        // `visibleFrame` already excludes the menu bar and the notch band, so
        // subtracting the band again took it off twice. And the panel hangs
        // from the screen it is PINNED to, which is not necessarily the one
        // macOS calls main — on a two-display desk those differ, and the
        // ceiling would be computed for a screen the panel is not on.
        let screen = selectedScreen ?? interactivePanel?.screen ?? NSScreen.main
        let available = screen?.visibleFrame.height ?? 560
        let ceiling = max(560, available - 80)
        renderedPanelSize = CGSize(
            width: ceil(min(size.width, 720)),
            height: ceil(min(size.height, ceiling))
        )
        positionInteractivePanel()
        if isExpanded, interactivePanel?.isVisible != true {
            showInteractivePanel()
        }
        updateAwakeBorderFrame(animated: true)
    }

    private func positionInteractivePanel() {
        guard
            let panel = interactivePanel,
            let screen = selectedScreen,
            let panelSize = renderedPanelSize
        else {
            return
        }

        let notchBandHeight = max(
            screen.safeAreaInsets.top,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        let frame = NSRect(
            x: screen.frame.midX - (panelSize.width / 2),
            y: screen.frame.maxY - notchBandHeight - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func removeInteractivePanel() {
        interactivePanel?.onEscape = nil
        interactivePanel?.orderOut(nil)
        interactivePanel?.close()
        interactivePanel = nil
        panelHostingView = nil
    }

    private func configurePassThroughWindow(_ window: NSWindow?) {
        guard let window else { return }
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior.formUnion([
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ])
    }

    private func installInteractionMonitors() {
        guard globalMouseDownMonitor == nil, localEventMonitor == nil else { return }

        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLeftMouseDown(at: NSEvent.mouseLocation)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53, self.isExpanded {
                self.collapse(reason: .manual)
                return nil
            }
            if event.type == .leftMouseDown {
                self.handleLeftMouseDown(at: NSEvent.mouseLocation)
            }
            return event
        }
    }

    private func removeInteractionMonitors() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func handleLeftMouseDown(at point: NSPoint) {
        guard isExpanded, !containsExpandedContent(at: point) else { return }
        collapse(reason: .manual)
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            var lastPointerInsideTime = ProcessInfo.processInfo.systemUptime

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                guard let self, self.isExpanded else { return }

                let now = ProcessInfo.processInfo.systemUptime
                if self.containsExpandedContent(at: NSEvent.mouseLocation) {
                    lastPointerInsideTime = now
                } else if now - lastPointerInsideTime >= 120 {
                    NSLog(
                        "Vibenotch watchdog force-collapsed a panel left expanded "
                            + "for 120 seconds without the pointer inside."
                    )
                    self.collapse(reason: .manual)
                    return
                }
            }
        }
    }

    private func resetExpansionState(reason: ExpansionReason) {
        if isExpanded {
            HoverDiag.log("resetExpansionState(reason: \(reason.rawValue))")
        }
        isExpanded = false
        expansionReason = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        interactivePanel?.orderOut(nil)
    }

    private func hideEveryNotch() async {
        if let notchedHUD {
            await notchedHUD.hide()
        }
        if let floatingPeek {
            await floatingPeek.hide()
        }
    }

    private func clearNotches() {
        removeInteractivePanel()
        notchedHUD = nil
        floatingPeek = nil
    }
}

extension NotchWindowManager: HoverControllerDelegate {
    func hoverControllerDidEnter(_ controller: HoverController) {
        expand(reason: .hover)
    }

    func hoverControllerDidExit(_ controller: HoverController) {
        collapse(reason: .hover)
    }

    func hoverController(_ controller: HoverController, containsExpandedPoint point: NSPoint) -> Bool {
        containsExpandedContent(at: point)
    }
}

@MainActor
/// Hosting view that acts on the first click even when its panel is not key —
/// a floating approval card must respond immediately, never swallow a click to "focus".
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class InteractiveNotchPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
