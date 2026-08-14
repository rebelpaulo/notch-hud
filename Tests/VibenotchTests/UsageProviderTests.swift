import Foundation
import Testing
@testable import Vibenotch

// MARK: - Fakes

private struct FakeUsageHTTP: UsageHTTPPerforming {
    let statusCode: Int
    let body: Data

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }
}

private struct FakeClaudeCredentials: ClaudeCredentialReading {
    func accessToken() throws -> String { "fake-claude-token" }
}

private struct FakeCodexCredentials: CodexCredentialReading {
    func read() throws -> (accessToken: String, accountID: String) {
        ("fake-codex-token", "fake-account-id")
    }
}

private func iso8601(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}

// MARK: - Claude, real captured payload

private let claudeFixture = Data("""
{"five_hour":{"utilization":9.0,"resets_at":"2026-08-14T22:20:00.408846+00:00","limit_dollars":null},
 "seven_day":{"utilization":84.0,"resets_at":"2026-08-16T17:00:00.408870+00:00"},
 "seven_day_opus":null,"seven_day_sonnet":null,
 "limits":[{"kind":"session","group":"session","percent":9,"severity":"normal","resets_at":"2026-08-14T22:20:00.408846+00:00","scope":null,"is_active":false},
           {"kind":"weekly_all","group":"weekly","percent":84,"severity":"warning","resets_at":"2026-08-16T17:00:00.408870+00:00","scope":null,"is_active":true},
           {"kind":"weekly_scoped","group":"weekly","percent":70,"severity":"normal","resets_at":"2026-08-16T17:00:00.409094+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
""".utf8)

@Test func claudeFetcherDecodesRealPayloadFromLimitsArray() async throws {
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: claudeFixture)
    )
    let now = Date()

    let snapshot = try await fetcher.fetch(now: now)

    #expect(snapshot.provider == .claude)
    #expect(snapshot.account == nil)
    #expect(snapshot.plan == nil)
    #expect(snapshot.windows.count == 3)

    let session = try #require(snapshot.window(.session))
    #expect(session.percentUsed == 9)
    #expect(session.severity == .normal)
    #expect(session.scopeLabel == nil)
    #expect(session.resetsAt == iso8601("2026-08-14T22:20:00.408846+00:00"))

    let accountWideWeekly = try #require(snapshot.window(.weekly))
    #expect(accountWideWeekly.percentUsed == 84)
    #expect(accountWideWeekly.severity == .warning)
    #expect(accountWideWeekly.scopeLabel == nil)

    // The model-scoped weekly limit is the second `weekly` entry; window(_:)
    // deliberately prefers the account-wide one, so fetch it explicitly.
    let scoped = try #require(snapshot.windows.first { $0.scopeLabel == "Fable" })
    #expect(scoped.kind == .weekly)
    #expect(scoped.percentUsed == 70)
    #expect(scoped.severity == .normal)
    #expect(scoped.resetsAt == iso8601("2026-08-16T17:00:00.409094+00:00"))
}

@Test func claudeGroupSessionVsWeeklyDrivesKindNotTheKindField() async throws {
    // Regression guard for the documented exception: this provider has no
    // window-length field at all, so `group` (not the API's own `kind`
    // string, e.g. "weekly_scoped") must be what decides session vs weekly.
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: claudeFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.windows.allSatisfy { $0.kind == .session || $0.kind == .weekly })
    #expect(snapshot.windows.filter { $0.kind == .weekly }.count == 2)
    #expect(snapshot.windows.filter { $0.kind == .session }.count == 1)
}

// MARK: - Codex, real captured payload

private let codexFixture = Data("""
{"account_id":"acct-123","email":"someone@example.com","plan_type":"prolite",
 "rate_limit":{"allowed":true,"limit_reached":false,
   "primary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_after_seconds":480107,"reset_at":1787211467},
   "secondary_window":null},
 "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox",
   "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1787336160},"secondary_window":null}}],
 "credits":{"has_credits":false,"balance":"0"}}
""".utf8)

@Test func codexFetcherDecodesRealPayload() async throws {
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: codexFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.provider == .codex)
    #expect(snapshot.account == "someone@example.com")
    #expect(snapshot.plan == "prolite")
    // secondary_window is null and must not turn into a phantom window.
    #expect(snapshot.windows.count == 2)

    let primary = try #require(snapshot.windows.first { $0.scopeLabel == nil })
    #expect(primary.percentUsed == 7)
    #expect(primary.windowLength == 604800)
    #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_787_211_467))
    #expect(primary.severity == .derived(fromPercentUsed: 7))

    let additional = try #require(snapshot.windows.first { $0.scopeLabel == "GPT-5.3-Codex-Spark" })
    #expect(additional.percentUsed == 0)
    #expect(additional.kind == .weekly)
}

@Test func codexPrimaryWindowClassifiesByDurationNotBySlotName() async throws {
    // THE important part: on this real account the 604800-second window
    // arrived in `primary_window`, which sounds like "session". Trusting the
    // slot name would mislabel a weekly quota as a session one.
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: codexFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    let primary = try #require(snapshot.windows.first { $0.scopeLabel == nil })
    #expect(primary.kind == .weekly)
}

// MARK: - Shared failure handling

@Test func claude401SurfacesAsCredentialExpired() async {
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 401, body: Data())
    )

    await #expect(throws: UsageUnavailable.credentialExpired) {
        try await fetcher.fetch(now: Date())
    }
}

@Test func codex401SurfacesAsCredentialExpired() async {
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 401, body: Data())
    )

    await #expect(throws: UsageUnavailable.credentialExpired) {
        try await fetcher.fetch(now: Date())
    }
}

@Test func claudeGarbageBodySurfacesAsUnexpectedResponse() async throws {
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: Data("not json at all".utf8))
    )

    do {
        _ = try await fetcher.fetch(now: Date())
        Issue.record("expected unexpectedResponse to be thrown")
    } catch UsageUnavailable.unexpectedResponse {
        // expected
    }
}

@Test func codexGarbageBodySurfacesAsUnexpectedResponse() async throws {
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: Data("{not even close".utf8))
    )

    do {
        _ = try await fetcher.fetch(now: Date())
        Issue.record("expected unexpectedResponse to be thrown")
    } catch UsageUnavailable.unexpectedResponse {
        // expected
    }
}
