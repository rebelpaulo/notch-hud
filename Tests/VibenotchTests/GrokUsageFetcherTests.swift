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

/// Two different fixed responses keyed by host path, so a single fetch that
/// hits both Grok endpoints (billing, then settings) can be exercised in one
/// fake instead of two.
private struct TwoEndpointFakeHTTP: UsageHTTPPerforming {
    let billingStatus: Int
    let billingBody: Data
    let settingsStatus: Int
    let settingsBody: Data

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let isSettings = request.url?.path == "/v1/settings"
        let status = isSettings ? settingsStatus : billingStatus
        let body = isSettings ? settingsBody : billingBody
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }
}

/// Fails the test if the fetcher ever makes a network call — used to prove an
/// expired/missing credential short-circuits before any request goes out.
private struct FailIfCalledHTTP: UsageHTTPPerforming {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        Issue.record("HTTP should not have been called")
        throw UsageUnavailable.network("unexpected call")
    }
}

private struct FakeGrokCredentials: GrokCredentialReading {
    let credential: GrokCredential
    func read() throws -> GrokCredential { credential }
}

private struct ThrowingGrokCredentials: GrokCredentialReading {
    let error: UsageUnavailable
    func read() throws -> GrokCredential { throw error }
}

private func iso8601(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}

/// Writes a `.grok/auth.json` under a fresh temp directory and hands back a
/// `FileGrokCredentialReader` pointed at it, so the expiry-parsing test
/// exercises the real reader instead of a fake standing in for it — while
/// never touching the real `~/.grok`.
private func fileReader(authJSON: String, now: @escaping @Sendable () -> Date = { Date() }) -> FileGrokCredentialReader {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-usage-fetcher-tests-\(UUID().uuidString)", isDirectory: true)
    let grokDir = home.appendingPathComponent(".grok", isDirectory: true)
    try? FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
    try? Data(authJSON.utf8).write(to: grokDir.appendingPathComponent("auth.json"))
    return FileGrokCredentialReader(homeDirectory: home, now: now)
}

// MARK: - Grok, real captured payload

private let grokFixture = Data("""
{"config":{"creditUsagePercent":1.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-14T14:23:52.962831+00:00","end":"2026-08-21T14:23:52.962831+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},"isUnifiedBillingUser":true,"productUsage":[{"product":"GrokImagine","usagePercent":1.0},{"product":"GrokBuild"}]}}
""".utf8)

private let settingsFixture = Data("""
{"subscription_tier_display":"SuperGrok Lite","allow_access":true}
""".utf8)

@Test func grokFetcherDecodesTheWeeklyWindowAt1PercentWithTheRightReset() async throws {
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: "someone@example.com")),
        http: TwoEndpointFakeHTTP(billingStatus: 200, billingBody: grokFixture, settingsStatus: 200, settingsBody: settingsFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.provider == .grok)
    #expect(snapshot.account == "someone@example.com")
    #expect(snapshot.plan == "SuperGrok Lite")

    let weekly = try #require(snapshot.window(.weekly))
    #expect(weekly.percentUsed == 1)
    #expect(weekly.scopeLabel == nil)
    #expect(weekly.resetsAt == iso8601("2026-08-21T14:23:52.962831+00:00"))
    // Derived from end - start, not hardcoded: 7 days exactly here. A small
    // tolerance absorbs the sub-microsecond float error ISO8601 parsing of
    // two large, independently-rounded timestamps can introduce.
    #expect(abs((weekly.windowLength ?? 0) - 7 * 86_400) < 0.01)
}

@Test func grokProductUsageEntryWithNoUsagePercentProducesAZeroWindowNotADroppedOne() async throws {
    // GrokBuild in the captured payload has no `usagePercent` key at all —
    // proto3 omits a zero value, so that means 0%, and must NOT be dropped
    // the way ClaudeUsageFetcher/CodexUsageFetcher would drop a missing
    // percentage.
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: nil)),
        http: TwoEndpointFakeHTTP(billingStatus: 200, billingBody: grokFixture, settingsStatus: 200, settingsBody: settingsFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    let build = try #require(snapshot.windows.first { $0.scopeLabel == "Build" })
    #expect(build.percentUsed == 0)

    let imagine = try #require(snapshot.windows.first { $0.scopeLabel == "Imagine" })
    #expect(imagine.percentUsed == 1)
}

@Test func grokAbsentCreditUsagePercentProducesAZeroPercentWeeklyWindowRatherThanNothing() async throws {
    let fixture = Data("""
    {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-14T14:23:52.962831+00:00","end":"2026-08-21T14:23:52.962831+00:00"},"productUsage":[]}}
    """.utf8)
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: nil)),
        http: TwoEndpointFakeHTTP(billingStatus: 200, billingBody: fixture, settingsStatus: 200, settingsBody: settingsFixture)
    )

    let snapshot = try await fetcher.fetch(now: Date())

    let weekly = try #require(snapshot.window(.weekly))
    #expect(weekly.percentUsed == 0)
}

// MARK: - Credentials

@Test func grokExpiredTokenYieldsNotLoggedInWithNoRequestAttempted() async {
    let expiresAt = "2026-01-01T00:00:00.000000+00:00"
    let authJSON = """
    {"https://auth.x.ai::abc-123":{"key":"should-never-be-sent","refresh_token":"r","expires_at":"\(expiresAt)","email":"someone@example.com"}}
    """
    let fetcher = GrokUsageFetcher(
        credentials: fileReader(authJSON: authJSON, now: { iso8601("2026-08-19T00:00:00.000000+00:00") }),
        http: FailIfCalledHTTP()
    )

    await #expect(throws: UsageUnavailable.notLoggedIn) {
        try await fetcher.fetch(now: Date())
    }
}

@Test func grokMissingAuthFileYieldsNotLoggedInWithNoRequestAttempted() async {
    let fetcher = GrokUsageFetcher(
        credentials: FileGrokCredentialReader(
            homeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("grok-usage-fetcher-tests-missing-\(UUID().uuidString)", isDirectory: true)
        ),
        http: FailIfCalledHTTP()
    )

    await #expect(throws: UsageUnavailable.notLoggedIn) {
        try await fetcher.fetch(now: Date())
    }
}

@Test func grok401SurfacesAsCredentialExpired() async {
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: nil)),
        http: FakeUsageHTTP(statusCode: 401, body: Data())
    )

    await #expect(throws: UsageUnavailable.credentialExpired) {
        try await fetcher.fetch(now: Date())
    }
}

@Test func grokGarbageBodySurfacesAsUnexpectedResponse() async throws {
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: nil)),
        http: FakeUsageHTTP(statusCode: 200, body: Data("not json at all".utf8))
    )

    do {
        _ = try await fetcher.fetch(now: Date())
        Issue.record("expected unexpectedResponse to be thrown")
    } catch UsageUnavailable.unexpectedResponse {
        // expected
    }
}

// MARK: - Plan lookup (Endpoint B) is best-effort

@Test func grokSettingsFailureStillYieldsTheGaugeWithPlanNil() async throws {
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: "someone@example.com")),
        http: TwoEndpointFakeHTTP(billingStatus: 200, billingBody: grokFixture, settingsStatus: 500, settingsBody: Data())
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.plan == nil)
    #expect(snapshot.billing == .plan(nil))
    // The quota itself must be unaffected by the plan lookup failing.
    #expect(snapshot.window(.weekly)?.percentUsed == 1)
}

@Test func grokSettingsGarbageBodyStillYieldsTheGaugeWithPlanNil() async throws {
    let fetcher = GrokUsageFetcher(
        credentials: FakeGrokCredentials(credential: GrokCredential(key: "fake-grok-key", email: nil)),
        http: TwoEndpointFakeHTTP(
            billingStatus: 200, billingBody: grokFixture,
            settingsStatus: 200, settingsBody: Data("not json".utf8)
        )
    )

    let snapshot = try await fetcher.fetch(now: Date())

    #expect(snapshot.plan == nil)
    #expect(snapshot.window(.weekly)?.percentUsed == 1)
}
