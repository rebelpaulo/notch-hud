import Foundation

/// Reads Codex CLI/Desktop usage from the ChatGPT backend endpoint the CLI
/// itself calls.
struct CodexUsageFetcher: UsageFetching {
    let kind: UsageProviderKind = .codex

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let credentials: CodexCredentialReading
    private let http: UsageHTTPPerforming

    init(
        credentials: CodexCredentialReading = FileCodexCredentialReader(),
        http: UsageHTTPPerforming = URLSessionUsageHTTP()
    ) {
        self.credentials = credentials
        self.http = http
    }

    func fetch(now: Date) async throws -> UsageSnapshot {
        let creds = try credentials.read()

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue(creds.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await http.perform(request)
        } catch let error as UsageUnavailable {
            throw error
        } catch {
            throw UsageUnavailable.network(error.localizedDescription)
        }

        if let failure = UsageHTTPStatus.failure(for: response) {
            throw failure
        }

        guard let payload = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else {
            throw UsageUnavailable.unexpectedResponse("codex usage payload did not match the expected shape")
        }

        return UsageSnapshot(
            provider: .codex,
            account: payload.email,
            plan: payload.planType,
            windows: Self.windows(from: payload),
            capturedAt: now
        )
    }

    private static func windows(from payload: CodexUsageResponse) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let rateLimit = payload.rateLimit {
            windows.append(contentsOf: [rateLimit.primaryWindow, rateLimit.secondaryWindow]
                .compactMap { UsageWindow(codexWindow: $0, scopeLabel: nil) })
        }
        for additional in payload.additionalRateLimits ?? [] {
            if let window = UsageWindow(
                codexWindow: additional.rateLimit?.primaryWindow,
                scopeLabel: additional.limitName
            ) {
                windows.append(window)
            }
        }
        return windows
    }
}

private extension UsageWindow {
    /// `window` is optional because `secondary_window` (or an additional
    /// limit's primary window) can arrive as JSON null.
    init?(codexWindow window: CodexUsageResponse.Window?, scopeLabel: String?) {
        // Missing percent must not become 0% — that would read as "fine".
        guard let window, let percent = window.usedPercent else { return nil }
        self.init(
            // THE important part: classify by the window's actual length, not
            // by which slot it arrived in. On a real account here the
            // *primary* window was the 604800-second (weekly) one with
            // `secondary_window` null — trusting the slot name would have
            // printed "Session" over a weekly quota.
            kind: .classify(lengthSeconds: window.limitWindowSeconds),
            percentUsed: percent,
            resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) },
            windowLength: window.limitWindowSeconds,
            scopeLabel: scopeLabel,
            // Codex reports no severity of its own.
            severity: .derived(fromPercentUsed: percent)
        )
    }
}

/// Decoding target for `GET /backend-api/wham/usage`. Every field is
/// optional: an undocumented endpoint can rename or drop one without
/// crashing the app.
struct CodexUsageResponse: Decodable {
    struct Window: Decodable {
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        /// Epoch seconds, unlike Claude's ISO8601 strings.
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalLimit: Decodable {
        let limitName: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case rateLimit = "rate_limit"
        }
    }

    let email: String?
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalLimit]?

    enum CodingKeys: String, CodingKey {
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }
}
