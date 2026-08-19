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
 "code_review_rate_limit":null,
 "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox",
   "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1787336160},"secondary_window":null}}],
 "credits":{"has_credits":false,"balance":"0"},
 "rate_limit_reset_credits":{"available_count":0,"applicable_available_count":0}}
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
    #expect(snapshot.limitResetCredits == 0)
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

@Test func codexNullCodeReviewRateLimitProducesNoWindows() async throws {
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: codexFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.windows.contains { $0.scopeLabel == t("Code review") } == false)
}

@Test func codexCodeReviewRateLimitUsesScopedWindows() async throws {
    let body = """
    {"plan_type":"prolite","rate_limit":{
       "primary_window":{"used_percent":5,"limit_window_seconds":18000,"reset_at":1787211467},
       "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1787336160}},
     "code_review_rate_limit":{
       "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_at":1787211467},
       "secondary_window":{"used_percent":60,"limit_window_seconds":604800,"reset_at":1787336160}},
     "additional_rate_limits":[],
     "rate_limit_reset_credits":{"available_count":2}}
    """
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: Data(body.utf8))
    )

    let snapshot = try await fetcher.fetch(now: Date())
    let codeReview = snapshot.windows.filter { $0.scopeLabel == t("Code review") }

    #expect(codeReview.count == 2)
    #expect(codeReview.contains { $0.kind == .session && $0.percentUsed == 25 })
    #expect(codeReview.contains { $0.kind == .weekly && $0.percentUsed == 60 })
    #expect(snapshot.limitResetCredits == 2)
    // A scoped code-review quota must never claim the account-wide headline.
    #expect(snapshot.window(.session)?.scopeLabel == nil)
    #expect(snapshot.window(.weekly)?.scopeLabel == nil)
}

@Test func codexMissingOrRenamedResetCreditCountStaysAbsent() async throws {
    let body = """
    {"plan_type":"prolite","rate_limit":null,
     "rate_limit_reset_credits":{"renamed_available_count":4}}
    """
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: Data(body.utf8))
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.limitResetCredits == nil)
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

@Test func codexRejectsAnEpochThatIsNotInSeconds() {
    // The same instant, sent the two ways a service might send it. Only one of
    // them can be right, and the wrong one is not detectable by asking whether
    // the field is present — which is why it needs its own guard.
    let seconds = Date().timeIntervalSince1970 + 3600
    #expect(CodexUsageFetcher.resetDate(fromEpochSeconds: seconds) != nil)
    #expect(CodexUsageFetcher.resetDate(fromEpochSeconds: seconds * 1000) == nil)
    #expect(CodexUsageFetcher.resetDate(fromEpochSeconds: Double?.none) == nil)
}

// MARK: - Defect 1: an unclassifiable window must not become `.session`

@Test func codexMissingWindowLengthProducesNoWindow() async throws {
    // `limit_window_seconds` renamed/dropped: before the fix this silently
    // classified as `.session` (5h nominal) even though the real window was
    // the 604800s weekly one — a wrong pace projection on a weekly quota.
    let fixture = Data("""
    {"account_id":"acct-123","email":"someone@example.com","plan_type":"prolite",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":7,"reset_at":1787211467},
       "secondary_window":null},
     "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox",
       "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1787336160},"secondary_window":null}}],
     "credits":{"has_credits":false,"balance":"0"}}
    """.utf8)
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: fixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.windows.contains { $0.percentUsed == 7 } == false)
    #expect(snapshot.windows.count == 1)
}

@Test func claudeUnrecognizedOrMissingGroupProducesNoWindow() async throws {
    // `group` renamed/dropped or holding a value we've never seen: before the
    // fix this silently classified as `.session`.
    let fixture = Data("""
    {"limits":[
      {"percent":50,"severity":"normal","resets_at":"2026-08-16T17:00:00.000000+00:00","scope":null},
      {"group":"monthly","percent":60,"severity":"normal","resets_at":"2026-08-16T17:00:00.000000+00:00","scope":null}
    ]}
    """.utf8)
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: fixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.windows.isEmpty)
}

// MARK: - Defect 2: a scoped window whose scope can't be named must not claim account-wide

@Test func claudeScopedLimitWithoutModelNameDoesNotBecomeAccountWide() async throws {
    // The unnamed-scope entry arrives BEFORE the real account-wide one, so a
    // buggy nil scopeLabel here would win `window(.weekly)` and hide the real
    // account-wide quota.
    let fixture = Data("""
    {"limits":[
      {"group":"weekly","percent":70,"severity":"normal","resets_at":"2026-08-16T17:00:00.000000+00:00","scope":{"model":{"id":"m1","display_name":null},"surface":null}},
      {"group":"weekly","percent":84,"severity":"warning","resets_at":"2026-08-16T18:00:00.000000+00:00","scope":null}
    ]}
    """.utf8)
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: fixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    let accountWide = try #require(snapshot.window(.weekly))
    #expect(accountWide.percentUsed == 84)
    #expect(snapshot.windows.contains { $0.percentUsed == 70 && $0.scopeLabel != nil })
}

@Test func codexAdditionalLimitWithoutNameDoesNotBecomeAccountWide() async throws {
    // `limit_name` missing on an `additional_rate_limits` entry: it is still
    // a model-scoped limit by construction (it did not arrive in the
    // account-wide `rate_limit` slot), so it must not carry scopeLabel == nil.
    let fixture = Data("""
    {"account_id":"acct-123","email":"someone@example.com","plan_type":"prolite",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_at":1787211467},
       "secondary_window":null},
     "additional_rate_limits":[{"metered_feature":"codex_bengalfox",
       "rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1787336160},"secondary_window":null}}]}
    """.utf8)
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: fixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    let additional = try #require(snapshot.windows.first { $0.percentUsed == 40 })
    #expect(additional.scopeLabel != nil)
}

@Test func aPercentageThatIsNotAPercentageProducesNoWindow() {
    // From the Codex review: the fetchers passed whatever arrived straight
    // through, so a service answering 120 drew a bar reading "120% used" and
    // published that number to the phone.
    let good = UsageWindow.validated(
        kind: .weekly, percentUsed: 84, resetsAt: nil,
        windowLength: nil, scopeLabel: nil, severity: .warning
    )
    #expect(good != nil)

    for bad in [120.0, -5.0, .infinity, .nan] {
        #expect(UsageWindow.validated(
            kind: .weekly, percentUsed: bad, resetsAt: nil,
            windowLength: nil, scopeLabel: nil, severity: .normal
        ) == nil)
    }

    // The edges are legitimate: an untouched quota and an exhausted one.
    #expect(UsageWindow.validated(
        kind: .session, percentUsed: 0, resetsAt: nil,
        windowLength: nil, scopeLabel: nil, severity: .normal
    ) != nil)
    #expect(UsageWindow.validated(
        kind: .session, percentUsed: 100, resetsAt: nil,
        windowLength: nil, scopeLabel: nil, severity: .critical
    ) != nil)
}

@Test func codexScopedLimitsCarryBothWindowsNotJustTheFirst() async throws {
    // A scoped limit can have a secondary window, and reading only the primary
    // dropped it silently — the same slot-name assumption this file exists to
    // avoid, made one level down.
    let body = """
    {"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_at":1787211467}},
     "additional_rate_limits":[{"limit_name":"Spark","rate_limit":{
       "primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1787211467},
       "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1787336160}}}]}
    """
    let fetcher = CodexUsageFetcher(
        credentials: FakeCodexCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: Data(body.utf8))
    )

    let snapshot = try await fetcher.fetch(now: Date())
    let scoped = snapshot.windows.filter { $0.scopeLabel == "Spark" }
    #expect(scoped.count == 2)
    #expect(scoped.contains { $0.kind == .session && $0.percentUsed == 10 })
    #expect(scoped.contains { $0.kind == .weekly && $0.percentUsed == 40 })
}

@Test func anUnknownSeverityWordFallsBackToThePercentNotToNormal() async throws {
    // `.normal` is the one value that can never look alarming, which makes it
    // the worst possible default for an endpoint that renames things.
    let body = """
    {"limits":[{"kind":"weekly_all","group":"weekly","percent":95,"severity":"chartreuse",
                "resets_at":"2026-08-16T17:00:00Z","scope":null,"is_active":true}]}
    """
    let fetcher = ClaudeUsageFetcher(
        credentials: FakeClaudeCredentials(),
        http: FakeUsageHTTP(statusCode: 200, body: Data(body.utf8))
    )

    let snapshot = try await fetcher.fetch(now: Date())
    let weekly = try #require(snapshot.window(.weekly))
    #expect(weekly.severity == .critical)
    #expect(snapshot.worstSeverity == .critical)
}
