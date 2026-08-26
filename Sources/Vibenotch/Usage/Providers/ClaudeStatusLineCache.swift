import Foundation

protocol ClaudeUsageCacheReading: Sendable {
    func snapshot(now: Date) -> UsageSnapshot?
}

/// Used by dependency-injected fetcher tests and callers that explicitly want
/// the legacy network-only behavior.
struct EmptyClaudeUsageCache: ClaudeUsageCacheReading {
    func snapshot(now: Date) -> UsageSnapshot? { nil }
}

/// Reads the cache written by the Claude Code statusLine integration.
/// Invalid cache content is indistinguishable from a miss: the caller falls
/// back to its existing authenticated usage request rather than showing a
/// misleading zero or a partially trusted snapshot.
struct FileClaudeStatusLineCache: ClaudeUsageCacheReading {
    static let defaultMaxAge: TimeInterval = 120
    private static let allowedClockSkew: TimeInterval = 5
    private static let plausibleResetDistance: TimeInterval = 2 * 365 * 24 * 3600

    private let cacheURL: URL
    private let maxAge: TimeInterval

    init(
        cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibenotch", isDirectory: true)
            .appendingPathComponent("claude-usage.json"),
        maxAge: TimeInterval = Self.defaultMaxAge
    ) {
        self.cacheURL = cacheURL
        self.maxAge = maxAge
    }

    func snapshot(now: Date) -> UsageSnapshot? {
        guard maxAge >= 0, let data = try? Data(contentsOf: cacheURL), !data.isEmpty else {
            return nil
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        guard payload.schemaVersion == 1, payload.capturedAt.isFinite else {
            return nil
        }

        let capturedAt = Date(timeIntervalSince1970: payload.capturedAt)
        let age = now.timeIntervalSince(capturedAt)
        guard age >= -Self.allowedClockSkew, age <= maxAge else {
            return nil
        }

        var windows: [UsageWindow] = []
        if let fiveHour = payload.rateLimits.fiveHour {
            guard let window = validatedWindow(
                fiveHour,
                kind: .session,
                capturedAt: capturedAt
            ) else {
                return nil
            }
            windows.append(window)
        }
        if let sevenDay = payload.rateLimits.sevenDay {
            guard let window = validatedWindow(
                sevenDay,
                kind: .weekly,
                capturedAt: capturedAt
            ) else {
                return nil
            }
            windows.append(window)
        }
        guard !windows.isEmpty else { return nil }

        return UsageSnapshot(
            provider: .claude,
            account: nil,
            plan: nil,
            billing: .plan(nil),
            windows: windows,
            capturedAt: capturedAt
        )
    }

    private func validatedWindow(
        _ cached: Payload.Window,
        kind: UsageWindowKind,
        capturedAt: Date
    ) -> UsageWindow? {
        guard cached.resetsAt.isFinite else { return nil }
        let resetsAt = Date(timeIntervalSince1970: cached.resetsAt)
        let resetDistance = resetsAt.timeIntervalSince(capturedAt)
        guard resetDistance >= -Self.allowedClockSkew,
              resetDistance <= Self.plausibleResetDistance
        else {
            // Catches milliseconds, corrupt epochs, and similarly impossible
            // values. A fresh cache may briefly outlive its reset, but the
            // reset still had to be current when that cache was captured.
            return nil
        }
        return UsageWindow.validated(
            kind: kind,
            percentUsed: cached.usedPercentage,
            resetsAt: resetsAt,
            windowLength: nil,
            scopeLabel: nil,
            severity: .derived(fromPercentUsed: cached.usedPercentage)
        )
    }
}

private extension FileClaudeStatusLineCache {
    struct Payload: Decodable {
        struct RateLimits: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                fiveHour = try Self.decodeWindow(.fiveHour, from: container)
                sevenDay = try Self.decodeWindow(.sevenDay, from: container)
            }

            private static func decodeWindow(
                _ key: CodingKeys,
                from container: KeyedDecodingContainer<CodingKeys>
            ) throws -> Window? {
                guard container.contains(key) else { return nil }
                guard try !container.decodeNil(forKey: key) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key,
                        in: container,
                        debugDescription: "A present quota window cannot be null"
                    )
                }
                return try container.decode(Window.self, forKey: key)
            }

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        struct Window: Decodable {
            let usedPercentage: Double
            let resetsAt: Double

            enum CodingKeys: String, CodingKey {
                case usedPercentage = "used_percentage"
                case resetsAt = "resets_at"
            }
        }

        let schemaVersion: Int
        let capturedAt: Double
        let rateLimits: RateLimits

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case capturedAt = "captured_at"
            case rateLimits = "rate_limits"
        }
    }
}
