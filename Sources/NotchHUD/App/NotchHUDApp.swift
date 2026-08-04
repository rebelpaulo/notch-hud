import AppKit
import SwiftUI

@main
@MainActor
struct NotchHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var sessionStore: SessionStore?
    private var pendingStore: PendingStore?
    private var focusDispatcher: FocusDispatcher?
    private var spoolWatcher: SpoolWatcher?
    private var pendingWatcher: PendingWatcher?
    private var stalenessSweeper: StalenessSweeper?
    private var codexRolloutPoller: CodexRolloutPoller?
    private var windowManager: NotchWindowManager?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let environment = AppEnvironment()
        let sessionStore = SessionStore()
        let pendingStore = PendingStore()
        let focusDispatcher = FocusDispatcher()
        let spoolWatcher = SpoolWatcher(spoolURL: environment.spoolURL, store: sessionStore)
        let codexRolloutPoller = CodexRolloutPoller(spoolURL: environment.spoolURL)
        let stalenessSweeper = StalenessSweeper(
            spoolURL: environment.spoolURL,
            store: sessionStore,
            workingStaleSeconds: environment.workingStaleSeconds,
            dropSeconds: environment.dropSeconds
        )
        let windowManager = NotchWindowManager(
            environment: environment,
            store: sessionStore,
            pendingStore: pendingStore,
            focusDispatcher: focusDispatcher
        )
        let pendingWatcher = PendingWatcher(pendingURL: environment.pendingURL) {
            [weak windowManager] approvals in
            windowManager?.applyPendingApprovals(approvals)
        }
        self.environment = environment
        self.sessionStore = sessionStore
        self.pendingStore = pendingStore
        self.focusDispatcher = focusDispatcher
        self.spoolWatcher = spoolWatcher
        self.pendingWatcher = pendingWatcher
        self.stalenessSweeper = stalenessSweeper
        self.codexRolloutPoller = codexRolloutPoller
        self.windowManager = windowManager

        spoolWatcher.start()
        codexRolloutPoller.start()
        pendingWatcher.start()
        stalenessSweeper.start()
        windowManager.boot()
        installStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager?.shutdown()
        codexRolloutPoller?.stop()
        stalenessSweeper?.stop()
        pendingWatcher?.stop()
        spoolWatcher?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func screenParametersDidChange(_ notification: Notification) {
        windowManager?.repinToBuiltInScreen()
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "checkmark.shield",
                accessibilityDescription: "NotchHUD"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NotchHUD"
        }

        let menu = NSMenu()
        let pauseItem = NSMenuItem(
            title: "Pause approvals",
            action: #selector(togglePauseApprovals(_:)),
            keyEquivalent: ""
        )
        pauseItem.target = self
        pauseItem.state = approvalsAreEnabled ? .off : .on
        menu.addItem(pauseItem)

        let collapseItem = NSMenuItem(
            title: "Collapse panel",
            action: #selector(collapsePanel(_:)),
            keyEquivalent: ""
        )
        collapseItem.target = self
        menu.addItem(collapseItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit NotchHUD",
            action: #selector(quitNotchHUD(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc
    private func togglePauseApprovals(_ sender: NSMenuItem) {
        let shouldPause = sender.state != .on
        guard writeApprovalsEnabled(!shouldPause) else { return }
        sender.state = shouldPause ? .on : .off
        if shouldPause {
            windowManager?.collapse(reason: .manual)
        }
    }

    @objc
    private func collapsePanel(_ sender: NSMenuItem) {
        windowManager?.collapse(reason: .manual)
    }

    @objc
    private func quitNotchHUD(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private var approvalsAreEnabled: Bool {
        guard let configURL = environment?.configURL,
              let data = try? Data(contentsOf: configURL),
              let rawObject = try? JSONSerialization.jsonObject(with: data),
              let object = rawObject as? [String: Any]
        else {
            return false
        }
        return object["approvals"] as? Bool == true
    }

    private func writeApprovalsEnabled(_ enabled: Bool) -> Bool {
        guard let configURL = environment?.configURL else { return false }

        do {
            var config: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: configURL.path) {
                let data = try Data(contentsOf: configURL)
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                config = existing
            }

            config["approvals"] = enabled
            var data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys]
            )
            data.append(0x0A)
            try data.write(to: configURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: configURL.path
            )
            return true
        } catch {
            NSLog(
                "NotchHUD could not update %@: %@",
                configURL.path,
                error.localizedDescription
            )
            return false
        }
    }
}
