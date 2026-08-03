import AppKit

protocol ClaudeDesktopRunningApplication: Sendable {
    @discardableResult
    func activate() -> Bool
}

protocol ClaudeDesktopWorkspace: Sendable {
    func runningApplications(bundleIdentifier: String) -> [any ClaudeDesktopRunningApplication]
}

struct SystemClaudeDesktopWorkspace: ClaudeDesktopWorkspace {
    func runningApplications(bundleIdentifier: String) -> [any ClaudeDesktopRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
            .map(SystemClaudeDesktopRunningApplication.init)
    }
}

private struct SystemClaudeDesktopRunningApplication: ClaudeDesktopRunningApplication, @unchecked Sendable {
    let application: NSRunningApplication

    @discardableResult
    func activate() -> Bool {
        application.activate(options: [])
    }
}
