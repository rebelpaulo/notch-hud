import Foundation

/// Whether a `claude remote-control` server is running, and how to start one.
///
/// Server mode is what puts the Mac in the Claude app's **Devices** list, so
/// new sessions can be started from the phone. That is a different thing from
/// resuming one conversation, which is why it gets its own control.
struct RemoteControlServer: Sendable {
    /// Matched on the argument pair rather than the word "claude" alone: the
    /// machine is full of processes whose command line mentions claude, and
    /// matching those would report the server as running when it is not.
    static let processPattern = "claude remote-control"

    var runProcess: @Sendable (_ launchPath: String, _ arguments: [String]) -> Int32 = { launchPath, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    /// `pgrep -f` exits 0 when something matched.
    func isRunning() -> Bool {
        runProcess("/usr/bin/pgrep", ["-f", Self.processPattern]) == 0
    }

    /// Stops the server.
    ///
    /// The pattern cannot hit a resumed conversation: those run
    /// `claude --remote-control --resume`, and "claude remote-control" is not
    /// a substring of that — the dashes are what keep the two apart.
    @discardableResult
    func stop() -> Bool {
        runProcess("/usr/bin/pkill", ["-f", Self.processPattern]) == 0
    }
}
