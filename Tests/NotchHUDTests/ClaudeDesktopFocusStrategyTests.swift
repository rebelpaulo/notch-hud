import Foundation
import Testing
@testable import NotchHUD

@Test func claudeDesktopStrategyCanHandleOnlyDesktopSource() {
    let strategy = ClaudeDesktopFocusStrategy(workspace: FakeClaudeDesktopWorkspace(applications: []))

    #expect(strategy.canHandle(makeFocusSession(source: "claude-desktop")))
    #expect(!strategy.canHandle(makeFocusSession(source: "notch-emit")))
}

@Test func claudeDesktopStrategyActivatesFirstRunningApplication() throws {
    let first = FakeClaudeDesktopRunningApplication()
    let second = FakeClaudeDesktopRunningApplication()
    let workspace = FakeClaudeDesktopWorkspace(applications: [first, second])
    let strategy = ClaudeDesktopFocusStrategy(workspace: workspace)

    try strategy.focus(makeFocusSession(source: "claude-desktop"))

    #expect(workspace.requestedBundleIdentifier == "com.anthropic.claudefordesktop")
    #expect(first.wasActivated)
    #expect(!second.wasActivated)
}

@Test func claudeDesktopStrategyReturnsNotFoundWhenAppIsNotRunning() {
    let strategy = ClaudeDesktopFocusStrategy(workspace: FakeClaudeDesktopWorkspace(applications: []))

    #expect(throws: FocusError.notFound) {
        try strategy.focus(makeFocusSession(source: "claude-desktop"))
    }
}

@MainActor
@Test func dispatcherSelectsDesktopAndTerminalStrategies() {
    let dispatcher = FocusDispatcher()
    let desktop = makeFocusSession(source: "claude-desktop")
    let terminal = makeFocusSession(
        source: "notch-emit",
        terminal: TerminalIdentity(
            termProgram: "Apple_Terminal",
            tty: "/dev/ttys001",
            itermSessionId: nil,
            weztermPane: nil,
            kittyWindowId: nil,
            windowId: nil
        )
    )

    #expect(dispatcher.strategy(for: desktop) is ClaudeDesktopFocusStrategy)
    #expect(dispatcher.strategy(for: terminal) is TerminalAppStrategy)
}

private final class FakeClaudeDesktopRunningApplication: ClaudeDesktopRunningApplication, @unchecked Sendable {
    private let lock = NSLock()
    private var activated = false

    var wasActivated: Bool {
        lock.withLock { activated }
    }

    func activate() -> Bool {
        lock.withLock { activated = true }
        return true
    }
}

private final class FakeClaudeDesktopWorkspace: ClaudeDesktopWorkspace, @unchecked Sendable {
    private let applications: [any ClaudeDesktopRunningApplication]
    private let lock = NSLock()
    private var requestedIdentifier: String?

    init(applications: [any ClaudeDesktopRunningApplication]) {
        self.applications = applications
    }

    var requestedBundleIdentifier: String? {
        lock.withLock { requestedIdentifier }
    }

    func runningApplications(bundleIdentifier: String) -> [any ClaudeDesktopRunningApplication] {
        lock.withLock { requestedIdentifier = bundleIdentifier }
        return applications
    }
}

private func makeFocusSession(
    source: String?,
    terminal: TerminalIdentity? = nil
) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: "focus-session",
            agent: "claude-code",
            status: .working,
            updated: "2026-08-04T12:00:00Z",
            seq: 1,
            terminal: terminal,
            source: source
        ),
        updatedAt: Date(timeIntervalSince1970: 1_775_300_400)
    )
}
