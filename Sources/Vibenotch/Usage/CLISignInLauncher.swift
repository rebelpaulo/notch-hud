import Foundation

/// Opens Terminal on the CLI's own sign-in command.
///
/// The one thing this app will NOT do is sign in on the user's behalf. Every
/// provider here keeps a refresh token next to the expired access token, so
/// minting a fresh one is mechanically easy — and it would mean Vibenotch
/// reading another program's refresh token, talking to an auth server as that
/// program, and writing the result back into its Keychain item. That is the
/// exact behaviour profile of software nobody should install, and the fact
/// that our intentions are good is not visible from the outside.
///
/// So the card hands the job back to the tool that owns the credential, in a
/// window the user can see. Same mechanism the updater already uses.
@MainActor
struct CLISignInLauncher {
    var runScript: (String) throws -> String?

    init(runScript: @escaping (String) throws -> String? = { try AppleScriptRunner.run($0) }) {
        self.runScript = runScript
    }

    /// Verified against each CLI's own `--help` rather than assumed: Claude
    /// nests it (`claude auth login`) while Codex and Grok do not.
    static func command(for provider: UsageProviderKind) -> String {
        switch provider {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .grok: "grok login"
        }
    }

    func launch(_ provider: UsageProviderKind) -> Result<Void, FocusError> {
        do {
            _ = try runScript(Self.appleScript(command: Self.command(for: provider)))
            return .success(())
        } catch let error as FocusError {
            return .failure(error)
        } catch {
            return .failure(.scriptFailed(error.localizedDescription))
        }
    }

    static func appleScript(command: String) -> String {
        """
        tell application "Terminal"
            activate
            do script "\(TerminalConversationResumer.escapedForAppleScript(command))"
        end tell
        """
    }
}
