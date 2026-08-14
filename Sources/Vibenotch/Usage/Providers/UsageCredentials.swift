import Foundation
import Security

/// Reads the OAuth token the Claude Code CLI already has, from the same
/// keychain item the CLI itself writes and reads.
protocol ClaudeCredentialReading: Sendable {
    func accessToken() throws -> String
}

struct KeychainClaudeCredentialReader: ClaudeCredentialReading {
    /// Exact service name the Claude Code CLI writes its keychain item under.
    static let service = "Claude Code-credentials"

    func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw UsageUnavailable.notLoggedIn
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else {
            // The item exists but its shape changed — that is our bug to fix,
            // not something "log in again" would resolve.
            throw UsageUnavailable.unexpectedResponse(
                "Claude Code-credentials keychain item did not contain claudeAiOauth.accessToken"
            )
        }
        return token
    }
}

/// Reads the OAuth token and account id the Codex CLI already has, from its
/// local auth file. No refresh: an expired token surfaces from the fetcher
/// as `.credentialExpired` on a 401, and the honest fix is the user running
/// the CLI again, not this app minting tokens on their behalf.
protocol CodexCredentialReading: Sendable {
    func read() throws -> (accessToken: String, accountID: String)
}

// FileManager isn't Sendable per the compiler, but Apple documents `.default`
// (and any instance used read-only, as here) as thread-safe.
struct FileCodexCredentialReader: CodexCredentialReading, @unchecked Sendable {
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    func read() throws -> (accessToken: String, accountID: String) {
        let codexHome: URL
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            codexHome = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            codexHome = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }
        let authURL = codexHome.appendingPathComponent("auth.json")

        guard let data = try? Data(contentsOf: authURL) else {
            throw UsageUnavailable.notLoggedIn
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String,
            let accountID = tokens["account_id"] as? String
        else {
            throw UsageUnavailable.unexpectedResponse(
                "auth.json did not contain tokens.access_token / tokens.account_id"
            )
        }
        return (accessToken, accountID)
    }
}
