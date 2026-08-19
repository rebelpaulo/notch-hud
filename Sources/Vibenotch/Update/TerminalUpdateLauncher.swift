import Foundation

@MainActor
struct TerminalUpdateLauncher {
    private let updaterURL: URL
    private let fileManager: FileManager
    var runScript: (String) throws -> String?

    init(
        updaterURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibenotch/bin/vibenotch-update", isDirectory: false),
        fileManager: FileManager = .default,
        runScript: @escaping (String) throws -> String? = { try AppleScriptRunner.run($0) }
    ) {
        self.updaterURL = updaterURL
        self.fileManager = fileManager
        self.runScript = runScript
    }

    func launch(_ update: AvailableUpdate) -> Result<Void, FocusError> {
        guard fileManager.fileExists(atPath: updaterURL.path) else {
            return .failure(.notFound)
        }

        let command: String
        do {
            command = try Self.command(updaterURL: updaterURL, tagName: update.tagName)
            _ = try runScript(Self.appleScript(command: command))
            return .success(())
        } catch let error as FocusError {
            return .failure(error)
        } catch {
            return .failure(.scriptFailed(error.localizedDescription))
        }
    }

    static func command(updaterURL: URL, tagName: String) throws -> String {
        guard let version = AppVersion(tagName), tagName == "v\(version)" else {
            throw UpdateLaunchError.invalidTag
        }
        return "/bin/sh \(TerminalConversationResumer.shellQuoted(updaterURL.path)) "
            + TerminalConversationResumer.shellQuoted(tagName)
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

enum UpdateLaunchError: Error {
    case invalidTag
}
