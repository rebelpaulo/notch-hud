import AppKit

protocol ClaudeDesktopRunningApplication: Sendable {
    @discardableResult
    func activate() -> Bool
}

/// Shared application-activation seam for desktop-agent focus strategies.
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
        // NSRunningApplication.activate (and NSWorkspace.openApplication) are
        // refused for background/accessory callers by macOS cooperative
        // activation — they return true without raising the app. LaunchServices
        // via /usr/bin/open (an Apple-signed requester) does raise it, no TCC.
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleIdentifier]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
