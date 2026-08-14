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
    let bridge: RemoteBridge

    private let suiteName: String
    private let defaults: UserDefaults

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
    /// Recorded rather than acted on: the bridge asking for a refresh is
    /// behaviour worth asserting, but a fake that actually fetched would put
    /// the network back into these tests.
    private(set) var refreshRequests: [TimeInterval] = []

    func refreshIfStale(maxAge: TimeInterval, now: Date) {
        refreshRequests.append(maxAge)
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

    func run(arguments: [String], stdin: String?) async -> CommandRunResult {
        calls.append(arguments)
        stdins.append(stdin)
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
