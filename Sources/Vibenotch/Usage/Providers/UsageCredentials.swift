import Foundation

/// Reads the OAuth token the Claude Code CLI already has.
protocol ClaudeCredentialReading: Sendable {
    func accessToken() throws -> String
}

struct ClaudeSecurityCommandOutput: Sendable {
    let terminationStatus: Int32
    let standardOutput: Data
}

/// Small process seam so tests can verify the exact executable and arguments
/// without ever reading the real login keychain.
protocol ClaudeSecurityCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) throws -> ClaudeSecurityCommandOutput
}

struct FoundationClaudeSecurityCommandRunner: ClaudeSecurityCommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> ClaudeSecurityCommandOutput {
        let process = Process()
        let standardOutput = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        // `security` diagnostics can contain keychain metadata. They are not
        // useful to the app and must not escape into a parent process or log.
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ClaudeSecurityCommandOutput(
            terminationStatus: process.terminationStatus,
            standardOutput: data
        )
    }
}

/// Uses the fixed Apple-signed keychain utility instead of asking Security.framework
/// to authorize the frequently rebuilt Vibenotch executable itself.
///
/// The command is deliberately not configurable in production and is launched
/// directly through `Process` (never through a shell). Its stdout is parsed in
/// memory and is never interpolated into an error or log message.
struct SecurityToolClaudeCredentialReader: ClaudeCredentialReading {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/security")
    static let arguments = [
        "find-generic-password",
        "-s", "Claude Code-credentials",
        "-w"
    ]

    private let runner: any ClaudeSecurityCommandRunning

    init(runner: any ClaudeSecurityCommandRunning = FoundationClaudeSecurityCommandRunner()) {
        self.runner = runner
    }

    func accessToken() throws -> String {
        let output: ClaudeSecurityCommandOutput
        do {
            output = try runner.run(
                executableURL: Self.executableURL,
                arguments: Self.arguments
            )
        } catch {
            // Never include the underlying process error: a custom process
            // environment could put sensitive command output in it.
            throw UsageUnavailable.unexpectedResponse(
                "could not execute the Claude credential helper"
            )
        }

        guard output.terminationStatus == 0 else {
            throw UsageUnavailable.notLoggedIn
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: output.standardOutput) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            // The item exists but its shape changed — that is our bug to fix,
            // not something "log in again" would resolve.
            throw UsageUnavailable.unexpectedResponse(
                "Claude credential helper output did not contain claudeAiOauth.accessToken"
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

/// One entry from `~/.grok/auth.json`: the bearer token and the account email
/// the CLI already obtained. `refresh_token` is deliberately not modeled —
/// this app never mints or refreshes tokens on the user's behalf, the same
/// stance `CodexCredentialReading` takes, and there is no reason to hold a
/// value we will never send anywhere.
struct GrokCredential: Sendable, Equatable {
    let key: String
    let email: String?
}

/// Reads the bearer token the Grok CLI already has, from its local auth file.
/// No refresh, for the same reason `FileCodexCredentialReader` has none: an
/// expired token is the user's problem to fix by signing in again, not this
/// app's problem to solve by minting one.
protocol GrokCredentialReading: Sendable {
    func read() throws -> GrokCredential
}

struct FileGrokCredentialReader: GrokCredentialReading, Sendable {
    private let homeDirectory: URL
    private let now: @Sendable () -> Date

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
    }

    func read() throws -> GrokCredential {
        let authURL = homeDirectory
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("auth.json")

        guard let data = try? Data(contentsOf: authURL) else {
            throw UsageUnavailable.notLoggedIn
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            // The file keys its one entry as "https://auth.x.ai::<uuid>".
            // `.values.first` is "the first entry" only because every
            // captured file so far has held exactly one — JSONSerialization
            // does not preserve source order for a dictionary with more.
            let entry = object.values.first as? [String: Any],
            let key = entry["key"] as? String
        else {
            throw UsageUnavailable.unexpectedResponse(
                "~/.grok/auth.json did not contain the expected <provider>::<uuid> entry with a key"
            )
        }

        // An expired token means not-signed-in — no request gets made with
        // it. A missing or unparseable expires_at is NOT treated as expired:
        // we cannot prove the token is stale, and refusing to try would turn
        // an unrelated field rename into a false "not logged in".
        if let expiresAt = Self.parseExpiresAt(entry["expires_at"]), expiresAt <= now() {
            throw UsageUnavailable.notLoggedIn
        }

        return GrokCredential(key: key, email: entry["email"] as? String)
    }

    /// `expires_at`'s wire type isn't documented anywhere this app can see,
    /// so this accepts either shape a CLI auth file plausibly uses: epoch
    /// seconds, or the same fractional-seconds ISO8601 string the billing
    /// endpoint's own timestamps use.
    private static func parseExpiresAt(_ raw: Any?) -> Date? {
        if let seconds = raw as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        guard let string = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }
}
