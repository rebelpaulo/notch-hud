import Foundation
import Testing
@testable import Vibenotch

@MainActor
@Test func theLocalScanRepeatsInsteadOfFreezingAfterTheFirstOne() async {
    // It used to refuse to run again once a series existed, so token counts
    // froze at whatever the first scan saw until the app restarted.
    let store = UsageStore(fetchers: [], scanner: LocalUsageScanner(
        claudeHomeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true),
        codexHomeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true)
    ))

    let start = Date()
    store.scanLocalIfNeeded(now: start)
    while store.lastLocalScan == nil { await Task.yield() }
    let first = store.lastLocalScan

    // Too soon: nothing should move.
    store.scanLocalIfNeeded(now: start.addingTimeInterval(60))
    #expect(store.lastLocalScan == first)

    // Past the window, it goes again.
    let later = start.addingTimeInterval(UsageStore.localScanMaxAge + 1)
    store.scanLocalIfNeeded(now: later)
    while store.lastLocalScan == first { await Task.yield() }
    #expect(store.lastLocalScan == later)
}

@MainActor
@Test func scanLocalIfNeededShowsTheCachedSeriesBeforeTheFullScanLands() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true)
    let claudeHome = home.appendingPathComponent("claude-home", isDirectory: true)
    let cacheHome = home.appendingPathComponent("cache-home", isDirectory: true)
    let projectDir = claudeHome.appendingPathComponent(".claude/projects/test-project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    let now = Date()
    let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    func line(messageID: String, requestID: String, input: Int, output: Int) -> String {
        #"""
        {"type":"assistant","timestamp":"\#(isoFormatter.string(from: now))","requestId":"\#(requestID)","message":{"id":"\#(messageID)","model":"claude-opus-5","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}
        """#
    }
    let sessionURL = projectDir.appendingPathComponent("session.jsonl")
    try (line(messageID: "msg_seed", requestID: "req_seed", input: 100, output: 10) + "\n")
        .write(to: sessionURL, atomically: true, encoding: .utf8)

    // Seed the on-disk cache the way an earlier launch would have left it.
    let seeder = LocalUsageScanner(claudeHomeURL: claudeHome, codexHomeURL: home.appendingPathComponent("codex-home"), cacheDirectoryURL: cacheHome)
    _ = await seeder.scan(now: now)

    // A new session appears on disk after the cache was written — the full
    // scan will see it, but a cache-only read cannot.
    let handle = try FileHandle(forWritingTo: sessionURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line(messageID: "msg_new", requestID: "req_new", input: 5, output: 1) + "\n").utf8))
    try handle.close()

    // A few hundred more brand-new files the seeded cache never saw, so the
    // full scan below has real directory-walk-and-parse work to do — a cache
    // decode alone would race it and this test would pass by luck rather
    // than by the ordering `scanLocalIfNeeded` actually guarantees.
    for i in 0..<400 {
        let url = projectDir.appendingPathComponent("extra-\(i).jsonl")
        try (line(messageID: "msg_extra_\(i)", requestID: "req_extra_\(i)", input: 1, output: 1) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    let store = UsageStore(fetchers: [], scanner: LocalUsageScanner(
        claudeHomeURL: claudeHome, codexHomeURL: home.appendingPathComponent("codex-home"), cacheDirectoryURL: cacheHome
    ))

    #expect(store.localSeries == nil)
    #expect(store.isScanningLocal == false) // hasn't been asked to scan yet

    store.scanLocalIfNeeded(now: now)
    #expect(store.isScanningLocal == true) // nothing published yet, cache-only bridge in flight

    // The cache-only bridge lands first: real numbers, but the stale total.
    while store.localSeries == nil { await Task.yield() }
    #expect(store.isScanningLocal == false)
    let bridged = try #require(store.localSeries)
    #expect(bridged.points.first { $0.provider == .claude }?.totalTokens == 110)

    // The full scan then supersedes it with the up-to-date total, including
    // the 400 brand-new files (2 tokens each) the cache-only bridge never
    // could have known about.
    while store.lastLocalScan == nil { await Task.yield() }
    let finalSeries = try #require(store.localSeries)
    #expect(finalSeries.points.first { $0.provider == .claude }?.totalTokens == 110 + 6 + 400 * 2)
}

@MainActor
@Test func aLateArrivingCacheOnlySeriesNeverOverwritesWhatIsAlreadyPublished() async {
    // Whichever answer landed first — a full scan or another cache-only
    // read — is always newer than a cache-only read that resolves later.
    // `applyCacheOnlyLocal`'s guard is what makes that true regardless of
    // actor-scheduling order between the two tasks `scanLocalIfNeeded`
    // starts, so it is exercised directly here rather than by trying to win
    // a race against real scheduling.
    let store = UsageStore(fetchers: [], scanner: LocalUsageScanner(
        claudeHomeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true),
        codexHomeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true)
    ))

    let firstSeries = LocalUsageSeries(
        points: [LocalUsageDayPoint(day: Date(), provider: .claude, totalTokens: 111, topModel: "claude-opus-5")],
        today: LocalUsageTotals(totalTokens: 111),
        trailingThirtyOneDays: LocalUsageTotals(totalTokens: 111)
    )
    let lateArrivingSeries = LocalUsageSeries(
        points: [LocalUsageDayPoint(day: Date(), provider: .claude, totalTokens: 222, topModel: "claude-opus-5")],
        today: LocalUsageTotals(totalTokens: 222),
        trailingThirtyOneDays: LocalUsageTotals(totalTokens: 222)
    )

    store.applyCacheOnlyLocal(firstSeries)
    #expect(store.localSeries == firstSeries)

    // A second, later-resolving cache-only publish must not clobber it.
    store.applyCacheOnlyLocal(lateArrivingSeries)
    #expect(store.localSeries == firstSeries)
}
