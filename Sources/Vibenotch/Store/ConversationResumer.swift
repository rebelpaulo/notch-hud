import Foundation

@MainActor
protocol ConversationResuming: Sendable {
    /// Reopens `conversation` with Remote Control, so it can be continued from
    /// the phone. Returns false if the terminal refused it.
    func resume(_ conversation: ClaudeConversation) -> Bool
}

/// Opens a real terminal window running `claude --remote-control --resume`.
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
        let command = Self.command(for: conversation)
        do {
            _ = try runScript("""
            tell application "Terminal"
                activate
                do script "\(Self.escapedForAppleScript(command))"
            end tell
            """)
            return true
        } catch {
            NSLog("Vibenotch could not resume %@: %@", conversation.id, error.localizedDescription)
            return false
        }
    }

    /// `--resume` alone would reconnect the Remote Control session recorded in
    /// the conversation, but only if it had one. Passing `--remote-control`
    /// makes it true either way, which is the point of the request.
    static func command(for conversation: ClaudeConversation) -> String {
        "cd \(shellQuoted(conversation.directory)) && claude --remote-control --resume \(shellQuoted(conversation.id))"
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
