import Foundation
import Testing
@testable import Vibenotch

@MainActor
@Test func remoteBridgePublishesTheExactUsageWireShape() async throws {
    // Pinned against the contract the phone is being built against in
    // parallel: key names, key order, and null-vs-omitted must match to the
    // character.
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }

    let sessionWindow = UsageWindow(
        kind: .session,
        percentUsed: 42,
        resetsAt: isoDate("2026-08-14T22:00:00Z"),
        windowLength: nil,
        scopeLabel: nil,
        severity: .normal
    )
    let weeklyWindow = UsageWindow(
        kind: .weekly,
        percentUsed: 84,
        resetsAt: isoDate("2026-08-16T17:00:00Z"),
        windowLength: nil,
        scopeLabel: nil,
        severity: .warning
    )
    let scopedWindow = UsageWindow(
        kind: .weekly,
        percentUsed: 95,
        resetsAt: isoDate("2026-08-16T17:00:00Z"),
        windowLength: nil,
        scopeLabel: "Fable",
        severity: .critical
    )
    let snapshot = UsageSnapshot(
        provider: .claude,
        account: "someone@example.com",
        plan: "prolite",
        billing: .plan("prolite"),
        windows: [sessionWindow, weeklyWindow, scopedWindow],
        capturedAt: isoDate("2026-08-14T12:00:00Z")
    )
    fixture.usage.entries[.claude] = .loaded(snapshot)
    fixture.usage.paceByWindowID[weeklyWindow.id] = UsagePace(
        expectedPercent: 73.1,
        deltaPercent: 10.9,
        runsOutAt: isoDate("2026-08-15T09:00:00Z")
    )

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.usagePutBodies().first)
    let expected = #"""
    {"usage":{"claude":{"plan":"prolite","account":"someone@example.com","windows":[{"kind":"session","percent_used":42.0,"resets_at":"2026-08-14T22:00:00Z","scope":null,"severity":"normal","expected_percent":null,"delta_percent":null,"runs_out_at":null},{"kind":"weekly","percent_used":84.0,"resets_at":"2026-08-16T17:00:00Z","scope":null,"severity":"warning","expected_percent":73.1,"delta_percent":10.9,"runs_out_at":"2026-08-15T09:00:00Z"},{"kind":"weekly","percent_used":95.0,"resets_at":"2026-08-16T17:00:00Z","scope":"Fable","severity":"critical","expected_percent":null,"delta_percent":null,"runs_out_at":null}]}}}
    """#
    #expect(body == expected)
}

@MainActor
@Test func remoteBridgePublishesAnUnchangedUsageSnapshotOnlyOnce() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(claudeSnapshot(percentUsed: 50))

    await fixture.bridge.checkNow(pollRemoteState: true)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usagePutBodies().count == 1)
}

@MainActor
@Test func remoteBridgeRetriesUsageAfterAFailedWrite() async throws {
    // Caching on a failed write would suppress every later attempt — quotas
    // can sit unchanged for a long time, so the retry might not come again
    // for a while.
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(claudeSnapshot(percentUsed: 50))
    await fixture.runner.setFailStatePut(true)

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.usagePutBodies().count == 1)

    await fixture.runner.setFailStatePut(false)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usagePutBodies().count == 2)
}

@MainActor
@Test func remoteBridgeClearsPublishedUsageAfterARestartWhenFetchesSettleEmpty() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(claudeSnapshot(percentUsed: 50))

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.usagePutBodies().count == 1)

    // The in-memory cache disappears here. Only persisted evidence of the
    // successful write can tell the new bridge that empty is a real change.
    fixture.usage.entries[.claude] = .failed(.notLoggedIn)
    fixture.relaunchBridge()
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usagePutBodies().last == #"{"usage":{}}"#)
}

@MainActor
@Test func remoteBridgeOmitsAProviderWithNoLoadedSnapshotInsteadOfSendingNull() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(claudeSnapshot(percentUsed: 50))
    fixture.usage.entries[.codex] = .failed(.notLoggedIn)

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.usagePutBodies().first)
    #expect(body.contains("\"claude\""))
    #expect(!body.contains("codex"))
}

@MainActor
@Test func remoteBridgePublishesNothingWhenNoProviderHasLoaded() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.codex] = .loading

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usagePutBodies().isEmpty)
}

@MainActor
@Test func remoteBridgePublishesTheExactUsageHistoryWireShape() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }

    let today = startOfToday()
    let yesterday = day(offset: -1, from: today)
    fixture.usage.localSeries = LocalUsageSeries(
        points: [
            LocalUsageDayPoint(day: yesterday, provider: .claude, totalTokens: 12_000, topModel: "claude-fable-4"),
            LocalUsageDayPoint(day: today, provider: .claude, totalTokens: 967_461_947, topModel: "claude-fable-5"),
            LocalUsageDayPoint(day: today, provider: .codex, totalTokens: 500, topModel: "gpt-6"),
        ],
        today: .zero,
        trailingThirtyOneDays: .zero
    )

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.usageHistoryPutBodies().first)
    let todayString = wireDayString(today)
    let yesterdayString = wireDayString(yesterday)
    let expected = #"""
    {"usage_history":{"claude":{"days":[{"day":"\#(yesterdayString)","tokens":12000},{"day":"\#(todayString)","tokens":967461947}],"top_model":"claude-fable-5"},"codex":{"days":[{"day":"\#(todayString)","tokens":500}],"top_model":"gpt-6"}}}
    """#
    #expect(body == expected)
}

@MainActor
@Test func remoteBridgeCapsUsageHistoryToTheTrailingWindowAndSortsAscending() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }

    let today = startOfToday()
    let insideWindow = day(offset: -(UsageStore.trailingDays - 1), from: today)
    let outsideWindow = day(offset: -UsageStore.trailingDays, from: today)
    fixture.usage.localSeries = LocalUsageSeries(
        // Inserted out of order on purpose: the publisher must sort, not
        // just pass through the scanner's own order.
        points: [
            LocalUsageDayPoint(day: today, provider: .claude, totalTokens: 100, topModel: "claude-fable-5"),
            LocalUsageDayPoint(day: outsideWindow, provider: .claude, totalTokens: 999_999, topModel: "claude-old"),
            LocalUsageDayPoint(day: insideWindow, provider: .claude, totalTokens: 50, topModel: "claude-fable-4"),
        ],
        today: .zero,
        trailingThirtyOneDays: .zero
    )

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.usageHistoryPutBodies().first)
    #expect(!body.contains(wireDayString(outsideWindow)))
    let insideIndex = body.range(of: wireDayString(insideWindow))
    let todayIndex = body.range(of: wireDayString(today))
    let insideStart = try #require(insideIndex).lowerBound
    let todayStart = try #require(todayIndex).lowerBound
    #expect(insideStart < todayStart)
    // The window's biggest day (999,999 tokens) is outside the window, so
    // the top model must come from what is actually published, not the
    // excluded day.
    #expect(body.contains("\"top_model\":\"claude-fable-5\""))
    #expect(!body.contains("claude-old"))
}

@MainActor
@Test func remoteBridgeOmitsAProviderWithNoUsageHistoryDays() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }

    fixture.usage.localSeries = LocalUsageSeries(
        points: [
            LocalUsageDayPoint(day: startOfToday(), provider: .claude, totalTokens: 100, topModel: "claude-fable-5"),
        ],
        today: .zero,
        trailingThirtyOneDays: .zero
    )

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.usageHistoryPutBodies().first)
    #expect(body.contains("\"claude\""))
    #expect(!body.contains("codex"))
}

@MainActor
@Test func remoteBridgePublishesNoUsageHistoryWhenNeitherProviderHasDays() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }

    // A scan that ran and found nothing (empty, not nil) is exactly as
    // silent as one that never ran.
    fixture.usage.localSeries = LocalUsageSeries(points: [], today: .zero, trailingThirtyOneDays: .zero)

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usageHistoryPutBodies().isEmpty)
}

@MainActor
@Test func remoteBridgePublishesAnUnchangedUsageHistoryOnlyOnce() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.localSeries = LocalUsageSeries(
        points: [
            LocalUsageDayPoint(day: startOfToday(), provider: .claude, totalTokens: 100, topModel: "claude-fable-5"),
        ],
        today: .zero,
        trailingThirtyOneDays: .zero
    )

    await fixture.bridge.checkNow(pollRemoteState: true)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usageHistoryPutBodies().count == 1)
}

@MainActor
@Test func remoteBridgeRetriesUsageHistoryAfterAFailedWrite() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.localSeries = LocalUsageSeries(
        points: [
            LocalUsageDayPoint(day: startOfToday(), provider: .claude, totalTokens: 100, topModel: "claude-fable-5"),
        ],
        today: .zero,
        trailingThirtyOneDays: .zero
    )
    await fixture.runner.setFailStatePut(true)

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.usageHistoryPutBodies().count == 1)

    await fixture.runner.setFailStatePut(false)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usageHistoryPutBodies().count == 2)
}

@MainActor
@Test func remoteBridgeClearsPublishedUsageHistoryAfterAnEmptyRestartScan() async throws {
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.localSeries = LocalUsageSeries(
        points: [
            LocalUsageDayPoint(
                day: startOfToday(),
                provider: .claude,
                totalTokens: 100,
                topModel: "claude-fable-5"
            ),
        ],
        today: .zero,
        trailingThirtyOneDays: .zero
    )

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.usageHistoryPutBodies().count == 1)

    fixture.usage.localSeries = LocalUsageSeries(points: [], today: .zero, trailingThirtyOneDays: .zero)
    fixture.relaunchBridge()
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usageHistoryPutBodies().last == #"{"usage_history":{}}"#)
}

@MainActor
@Test func remoteBridgeAsksForALocalScanEveryTick() async throws {
    // Without this the phone never gets history unless someone opens the
    // notch on the Mac — `scanLocalIfNeeded()` is cheap to call repeatedly.
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.usage.scanRequestCount == 1)
}

private func startOfToday() -> Date {
    Calendar.current.startOfDay(for: Date())
}

private func day(offset: Int, from date: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: offset, to: date)!
}

private func wireDayString(_ date: Date) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
}

private func isoDate(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)!
}

private func claudeSnapshot(percentUsed: Double) -> UsageSnapshot {
    UsageSnapshot(
        provider: .claude,
        account: "someone@example.com",
        plan: "prolite",
        billing: .plan("prolite"),
        windows: [
            UsageWindow(
                kind: .session,
                percentUsed: percentUsed,
                resetsAt: isoDate("2026-08-14T22:00:00Z"),
                windowLength: nil,
                scopeLabel: nil,
                severity: .normal
            )
        ],
        capturedAt: isoDate("2026-08-14T12:00:00Z")
    )
}

@MainActor
final class UsageBridgeFixture {
    let scratch: URL
    let engine = UsageFakeEngine()
    let store = UsageFakeSessionStore()
    let usage = FakeUsageStore()
    let runner: UsageFakeCommandRunner
    private(set) var bridge: RemoteBridge

    private let suiteName: String
    private let defaults: UserDefaults

    /// Rewrites the pairing file the way pointing the Mac at another remote
    /// would, so the bridge sees a URL it has not published to before.
    func repair(to url: String) throws {
        try "{\"url\":\"\(url)\",\"secret\":\"test-secret\"}".write(
            to: scratch.appendingPathComponent(".vibenotch/remote.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    func relaunchBridge() {
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: store,
            usageStore: usage,
            commandRunner: runner,
            powerSourceProvider: UsageFakePowerSource(),
            homeURL: scratch,
            userDefaults: defaults,
            // Never spawn a real pgrep from a test.
            remoteControlServer: RemoteControlServer(runProcess: { _, _ in 1 })
        )
    }

    init(stateOutput: String = #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#) throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-usage-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = scratch.appendingPathComponent(".vibenotch", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try #"{"url":"https://remote.example","secret":"test-secret"}"#.write(
            to: configDirectory.appendingPathComponent("remote.json"),
            atomically: true,
            encoding: .utf8
        )
        runner = UsageFakeCommandRunner(stateOutput: stateOutput)
        suiteName = "RemoteUsagePublishTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: store,
            usageStore: usage,
            commandRunner: runner,
            powerSourceProvider: UsageFakePowerSource(),
            homeURL: scratch,
            userDefaults: defaults,
            // Never spawn a real pgrep from a test.
            remoteControlServer: RemoteControlServer(runProcess: { _, _ in 1 })
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
final class UsageFakeEngine: RemoteKeepAwakeEngine {
    var mode: KeepAwakeMode = .manual
    var isOnACPower = true
    var lastOffReason: KeepAwakeOffReason?
    var config = KeepAwakeConfig()
    var isActive: Bool { mode != .off }

    func setMode(_ newMode: KeepAwakeMode, now: Date) {
        mode = newMode
        lastOffReason = nil
    }
}

@MainActor
final class UsageFakeSessionStore: RemoteSessionStoring {
    var sessions: [Session] = []
}

@MainActor
final class FakeUsageStore: RemoteUsageStoring {
    var entries: [UsageProviderKind: UsageStore.Entry] = [:]
    var paceByWindowID: [String: UsagePace] = [:]
    /// Set directly by a test, standing in for whatever the real scan would
    /// have produced. nil means "no scan has completed yet."
    var localSeries: LocalUsageSeries?
    /// Recorded rather than acted on: the bridge asking for a refresh is
    /// behaviour worth asserting, but a fake that actually fetched would put
    /// the network back into these tests.
    private(set) var refreshRequests: [TimeInterval] = []
    /// Same reasoning as `refreshRequests`: a fake that actually scanned
    /// would put the filesystem back into these tests, and the ticket only
    /// needs to know the bridge asked.
    private(set) var scanRequestCount = 0

    func refreshIfStale(maxAge: TimeInterval, now: Date) {
        refreshRequests.append(maxAge)
    }

    func scanLocalIfNeeded() {
        scanRequestCount += 1
    }

    func pace(for snapshot: UsageSnapshot, now: Date) -> [String: UsagePace] {
        var result: [String: UsagePace] = [:]
        for window in snapshot.windows {
            if let pace = paceByWindowID[window.id] {
                result[window.id] = pace
            }
        }
        return result
    }
}

final class UsageFakePowerSource: PowerSourceProviding, @unchecked Sendable {
    var percent: Int?
    var isOnACPower = true
}

actor UsageFakeCommandRunner: CommandRunning {
    private var calls: [[String]] = []
    private var stdins: [String?] = []
    private var stateOutput: String
    private var failStatePuts = false

    init(stateOutput: String) {
        self.stateOutput = stateOutput
    }

    func setFailStatePut(_ value: Bool) {
        failStatePuts = value
    }

    /// Makes a --state-put take long enough that a second tick can start while
    /// the first is still awaiting, which is the race the publishers guard.
    private var statePutDelay: Duration = .zero

    func setStatePutDelay(_ value: Duration) {
        statePutDelay = value
    }

    func run(arguments: [String], stdin: String?) async -> CommandRunResult {
        calls.append(arguments)
        stdins.append(stdin)
        if arguments == ["--state-put"], statePutDelay > .zero {
            try? await Task.sleep(for: statePutDelay)
        }
        if arguments == ["--state-put"], failStatePuts {
            return CommandRunResult(stdout: "", exitCode: 1)
        }
        return CommandRunResult(
            stdout: arguments == ["--state"] ? stateOutput : "{}",
            exitCode: 0
        )
    }

    /// Every `--state-put` body whose top-level key is the usage payload —
    /// distinguished from the battery/session/status writes that share the
    /// same endpoint.
    func usagePutBodies() -> [String] {
        zip(calls, stdins)
            .filter { $0.0 == ["--state-put"] }
            .compactMap { $0.1 }
            .filter { $0.contains("\"usage\"") }
    }

    /// Every `--state-put` body carrying the token-history payload —
    /// distinguished from `usagePutBodies()` by requiring the full
    /// `"usage_history"` key rather than the `"usage"` prefix it shares.
    func usageHistoryPutBodies() -> [String] {
        zip(calls, stdins)
            .filter { $0.0 == ["--state-put"] }
            .compactMap { $0.1 }
            .filter { $0.contains("\"usage_history\"") }
    }
}

@MainActor
@Test func remoteBridgeAsksForARefreshOnTheSlowCadenceNotTheTenSecondOne() async {
    // Without this the phone shows whatever was last looked at on the Mac:
    // opening the quota tab used to be the only thing that ever fetched.
    let fixture = try! UsageBridgeFixture()
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.usage.refreshRequests == [UsageStore.backgroundMaxAge])
    #expect(UsageStore.backgroundMaxAge > UsageStore.staleAfter)
}

@MainActor
@Test func rePairingRepublishesTheQuotasToTheNewRemote() async throws {
    // The quota publishers cache the last body they sent. Pairing to a
    // different remote makes that cache a claim about somebody else's
    // database — and quotas move slowly, so without clearing it the new
    // phone could sit blank for hours waiting for a percentage to change.
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(
        UsageSnapshot(
            provider: .claude,
            account: nil,
            plan: nil,
            billing: .plan(nil),
            windows: [
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 84,
                    resetsAt: isoDate("2026-08-16T17:00:00Z"),
                    windowLength: nil,
                    scopeLabel: nil,
                    severity: .warning
                )
            ],
            capturedAt: isoDate("2026-08-14T20:00:00Z")
        )
    )

    await fixture.bridge.checkNow(pollRemoteState: true)
    let firstCount = await fixture.runner.usagePutBodies().count
    #expect(firstCount > 0)

    // Same snapshot, second tick: nothing new to say.
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.usagePutBodies().count == firstCount)

    try fixture.repair(to: "https://elsewhere.example")
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.usagePutBodies().count > firstCount)
}

@MainActor
@Test func overlappingTicksPublishTheSameQuotaBodyOnlyOnce() async throws {
    // The check against the last published body and the write are separated by
    // an await, and the timer and an observation-driven checkNow() overlap
    // routinely. Without a guard both passes see "not published yet".
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(
        UsageSnapshot(
            provider: .claude,
            account: nil,
            plan: nil,
            billing: .plan(nil),
            windows: [
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 84,
                    resetsAt: isoDate("2026-08-16T17:00:00Z"),
                    windowLength: nil,
                    scopeLabel: nil,
                    severity: .warning
                )
            ],
            capturedAt: isoDate("2026-08-14T20:00:00Z")
        )
    )
    await fixture.runner.setStatePutDelay(.milliseconds(120))

    async let first: Void = fixture.bridge.checkNow(pollRemoteState: true)
    async let second: Void = fixture.bridge.checkNow(pollRemoteState: true)
    _ = await (first, second)

    #expect(await fixture.runner.usagePutBodies().count == 1)
}

@MainActor
@Test func anUnchangedSnapshotDoesNotRepublishAsTheClockMoves() async throws {
    // The publisher only writes when the body changes, and pace moves with the
    // clock — so deriving it from `Date()` made every tick a fresh body. In
    // production that was a database write every ten seconds.
    let fixture = try UsageBridgeFixture()
    defer { fixture.remove() }
    fixture.usage.entries[.claude] = .loaded(
        UsageSnapshot(
            provider: .claude,
            account: nil,
            plan: nil,
            billing: .plan(nil),
            windows: [
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 84,
                    resetsAt: Date().addingTimeInterval(3 * 24 * 3600),
                    windowLength: 7 * 24 * 3600,
                    scopeLabel: nil,
                    severity: .warning
                )
            ],
            capturedAt: Date()
        )
    )

    await fixture.bridge.checkNow(pollRemoteState: true)
    let afterFirst = await fixture.runner.usagePutBodies().count
    #expect(afterFirst == 1)

    // Two more ticks with real time passing between them. The snapshot has not
    // been refreshed, so there is nothing new to say.
    try await Task.sleep(for: .milliseconds(50))
    await fixture.bridge.checkNow(pollRemoteState: true)
    try await Task.sleep(for: .milliseconds(50))
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.usagePutBodies().count == afterFirst)
}
