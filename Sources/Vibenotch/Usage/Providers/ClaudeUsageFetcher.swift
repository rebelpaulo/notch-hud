import Foundation

/// Reads Claude Code's OAuth usage from the account the CLI is already
/// logged into.
///
/// The endpoint has no email/plan field, so `account`/`plan` on the snapshot
/// stay nil — fetching those is a separate request and a separate ticket.
struct ClaudeUsageFetcher: UsageFetching {
    let kind: UsageProviderKind = .claude

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let credentials: ClaudeCredentialReading
    private let http: UsageHTTPPerforming

    init(
        credentials: ClaudeCredentialReading = KeychainClaudeCredentialReader(),
        http: UsageHTTPPerforming = URLSessionUsageHTTP()
    ) {
        self.credentials = credentials
        self.http = http
    }

    func fetch(now: Date) async throws -> UsageSnapshot {
        let token = try credentials.accessToken()

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

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

        guard let payload = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            throw UsageUnavailable.unexpectedResponse("claude usage payload did not match the expected shape")
        }

        return UsageSnapshot(
            provider: .claude,
            account: nil,
            plan: nil,
            // We authenticate with the OAuth token Claude Code stores for a
            // signed-in subscription; there is no API-key path through this
            // fetcher, so anything it can reach is a plan.
            billing: .plan(nil),
            windows: Self.windows(from: payload),
            capturedAt: now
        )
    }

    /// `limits[]` is the source of truth: it carries severity and scope, and
    /// five_hour/seven_day are only a fallback for when it is absent or empty.
    private static func windows(from payload: ClaudeUsageResponse) -> [UsageWindow] {
        if let limits = payload.limits, !limits.isEmpty {
            return limits.compactMap(UsageWindow.init(claudeLimit:))
        }
        return [
            payload.fiveHour.flatMap { UsageWindow(claudeFallback: $0, kind: .session) },
            payload.sevenDay.flatMap { UsageWindow(claudeFallback: $0, kind: .weekly) }
        ].compactMap { $0 }
    }

    fileprivate static func severity(from raw: String?) -> UsageSeverity {
        guard let raw, let value = UsageSeverity(rawValue: raw) else { return .normal }
        return value
    }

    /// This response never states a window length, only `group` — Claude is
    /// the one exception to UsageWindowKind's "classify by duration" rule
    /// because there is no duration here to classify by.
    fileprivate static func kind(forGroup group: String?) -> UsageWindowKind {
        group == "weekly" ? .weekly : .session
    }

    /// Two formatters because `resets_at` is not guaranteed to carry
    /// fractional seconds even though every payload seen so far has them.
    fileprivate static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private extension UsageWindow {
    init?(claudeLimit limit: ClaudeUsageResponse.Limit) {
        // Missing percent must not become 0% — that would read as "fine".
        guard let percent = limit.percent else { return nil }
        self.init(
            kind: ClaudeUsageFetcher.kind(forGroup: limit.group),
            percentUsed: percent,
            resetsAt: ClaudeUsageFetcher.parseISO8601(limit.resetsAt),
            windowLength: nil,
            scopeLabel: limit.scope?.model?.displayName,
            severity: ClaudeUsageFetcher.severity(from: limit.severity)
        )
    }

    init?(claudeFallback window: ClaudeUsageResponse.Window, kind: UsageWindowKind) {
        guard let percent = window.utilization else { return nil }
        self.init(
            kind: kind,
            percentUsed: percent,
            resetsAt: ClaudeUsageFetcher.parseISO8601(window.resetsAt),
            windowLength: nil,
            scopeLabel: nil,
            // The fallback shape carries no severity of its own.
            severity: .derived(fromPercentUsed: percent)
        )
    }
}

/// Decoding target for `GET /api/oauth/usage`. Every field is optional: an
/// undocumented endpoint can rename or drop one without crashing the app.
struct ClaudeUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    struct Limit: Decodable {
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case group
            case percent
            case severity
            case resetsAt = "resets_at"
            case scope
        }
    }

    struct Scope: Decodable {
        let model: Model?

        struct Model: Decodable {
            let displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let limits: [Limit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}
