import Foundation

@MainActor
protocol ConversationResuming: Sendable {
    /// Reopens `conversation` with Remote Control, so it can be continued from
    /// the phone. Returns false if the terminal refused it.
    func resume(_ conversation: ClaudeConversation) -> Bool

    /// Starts a `claude remote-control` server in `directory`, which is what
    /// puts the Mac in the Claude app's Devices list. Different from resuming
    /// one conversation, which is why it is a separate call.
    func startRemoteControl(in directory: String) -> Bool
}

/// Opens a real terminal window running the command.
///
/// Not a detached background process: Remote Control needs the `claude`
/// process to stay alive, and a window is also the honest thing to leave
/// behind — the user can see exactly what their phone started on their Mac,
/// and close it.
@MainActor
struct TerminalConversationResumer: ConversationResuming {
    /// Whatever runs the script. Injected so tests never talk to a terminal.
    var runScript: (String) throws -> String? = { try AppleScriptRunner.run($0) }

    func resume(_ conversation: ClaudeConversation) -> Bool {
        run(Self.command(for: conversation), describing: conversation.id)
    }

    func startRemoteControl(in directory: String) -> Bool {
        run(Self.remoteControlCommand(inDirectory: directory), describing: "remote control")
    }

    private func run(_ command: String, describing subject: String) -> Bool {
        // Logged because one live run typed "ecd" instead of "cd" and could
        // not be reproduced. Without the exact command there is nothing to
        // inspect if it happens again.
        NSLog("Vibenotch terminal command: [%@]", command)
        do {
            _ = try runScript("""
            tell application "Terminal"
                activate
                do script "\(Self.escapedForAppleScript(command))"
            end tell
            """)
            return true
        } catch {
            NSLog("Vibenotch could not start %@: %@", subject, error.localizedDescription)
            return false
        }
    }

    /// `--resume` alone would reconnect the Remote Control session recorded in
    /// the conversation, but only if it had one. Passing `--remote-control`
    /// makes it true either way, which is the point of the request.
    static func command(for conversation: ClaudeConversation) -> String {
        "cd \(shellQuoted(conversation.directory)) && claude --remote-control --resume \(shellQuoted(conversation.id))"
    }

    static func remoteControlCommand(inDirectory directory: String) -> String {
        "cd \(shellQuoted(directory)) && claude remote-control"
    }

    /// Single quotes so nothing in a path can be read as shell syntax, with
    /// embedded quotes closed and reopened the POSIX way.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literals take the command as one double-quoted
    /// value, so backslashes and double quotes have to survive a second layer.
    static func escapedForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
