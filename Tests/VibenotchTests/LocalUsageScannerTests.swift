import Foundation
import Testing
@testable import Vibenotch

// MARK: - Day bucketing

@Test func dayBucketingUsesLocalMidnightNotUTC() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }

    // Anchor everything to Calendar.current's own idea of "local midnight"
    // rather than a hardcoded UTC instant — that is what makes the test
    // meaningful on a machine in any timezone. Two moments thirty minutes on
    // either side of that instant are, by construction, on different local
    // calendar days even though the timestamps are only an hour apart.
    let calendar = Calendar.current
    let now = Date()
    let localMidnight = calendar.startOfDay(for: now)
    let beforeMidnight = calendar.date(byAdding: .minute, value: -30, to: localMidnight)!
    let afterMidnight = calendar.date(byAdding: .minute, value: 30, to: localMidnight)!

    try fixture.writeClaudeSession(lines: [
        assistantLine(timestamp: beforeMidnight, messageID: "msg_before", requestID: "req_before", input: 100, output: 10),
        assistantLine(timestamp: afterMidnight, messageID: "msg_after", requestID: "req_after", input: 200, output: 20)
    ])

    let series = await fixture.scanner().scan(now: now)
    let claudePoints = series.points.filter { $0.provider == .claude }.sorted { $0.day < $1.day }

    #expect(claudePoints.count == 2)
    let previousDay = calendar.startOfDay(for: beforeMidnight)
    let today = calendar.startOfDay(for: afterMidnight)
    #expect(claudePoints[0].day == previousDay)
    #expect(claudePoints[0].totalTokens == 110)
    #expect(claudePoints[1].day == today)
    #expect(claudePoints[1].totalTokens == 220)
}

// MARK: - Dedupe

@Test func dedupesByMessageIdAndRequestIdTogether() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    // A resumed session can replay the same assistant message; the same
    // (message id, request id) pair appearing three times — as it genuinely
    // does in real transcripts on this machine — must count once.
    let line = assistantLine(timestamp: now, messageID: "msg_dup", requestID: "req_dup", input: 1_000, output: 100)
    try fixture.writeClaudeSession(lines: [line, line, line])

    let series = await fixture.scanner().scan(now: now)
    let point = try #require(series.points.first { $0.provider == .claude })

    #expect(point.totalTokens == 1_100)
}

// MARK: - Unpriced model

@Test func unknownModelContributesTokensButNoCostAndIsSurfacedAsUnpriced() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    try fixture.writeClaudeSession(lines: [
        assistantLine(
            timestamp: now,
            messageID: "msg_mystery",
            requestID: "req_mystery",
            input: 500,
            output: 50,
            model: "claude-mystery-model-not-in-price-table"
        )
    ])

    let series = await fixture.scanner().scan(now: now)
    let point = try #require(series.points.first { $0.provider == .claude })

    #expect(point.totalTokens == 550)
    #expect(point.topModel == "claude-mystery-model-not-in-price-table")
}

// MARK: - Cache

@Test func cacheSkipsAnUnmodifiedFileOnTheSecondScan() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    try fixture.writeClaudeSession(lines: [
        assistantLine(timestamp: now, messageID: "msg_cache", requestID: "req_cache", input: 10, output: 1)
    ])

    let scanner = fixture.scanner()
    let first = await scanner.scan(now: now)
    let firstStats = await scanner.lastScanStats
    #expect(firstStats.filesParsed == 1)
    #expect(firstStats.filesCached == 0)

    let second = await scanner.scan(now: now)
    let secondStats = await scanner.lastScanStats
    #expect(secondStats.filesParsed == 0)
    #expect(secondStats.filesCached == 1)
    #expect(secondStats.bytesRead == 0)
    #expect(second == first)
}

// MARK: - Append-only resume

@Test func appendingToAFileResumesFromTheCachedOffsetAndOnlyReadsTheAppendedBytes() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    let firstLine = assistantLine(timestamp: now, messageID: "msg_first", requestID: "req_first", input: 5_000, output: 500)
    let url = try fixture.writeClaudeSession(lines: [firstLine])

    let scanner = fixture.scanner()
    let first = await scanner.scan(now: now)
    let firstStats = await scanner.lastScanStats
    #expect(firstStats.bytesRead == (try fixture.fileSize(url)))
    #expect(first.points.first { $0.provider == .claude }?.totalTokens == 5_500)

    // Append, the way a live CLI session keeps writing to the same path.
    let secondLine = assistantLine(timestamp: now, messageID: "msg_second", requestID: "req_second", input: 10, output: 1)
    try fixture.appendRaw(secondLine + "\n", to: url)
    let appendedByteCount = (secondLine + "\n").utf8.count

    let second = await scanner.scan(now: now)
    let secondStats = await scanner.lastScanStats

    // The whole point of resuming: the second pass reads exactly the
    // appended tail, not the file from the top again.
    #expect(secondStats.bytesRead == appendedByteCount)
    #expect(secondStats.filesParsed == 1)
    #expect(second.points.first { $0.provider == .claude }?.totalTokens == 5_511)
}

@Test func truncatingAFileForcesAFullRescanInsteadOfMergingStaleTallies() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    let bigLine = assistantLine(timestamp: now, messageID: "msg_big_one", requestID: "req_big_one", input: 900_000_000, output: 900_000_000)
    let url = try fixture.writeClaudeSession(lines: [bigLine])

    let scanner = fixture.scanner()
    _ = await scanner.scan(now: now)
    let firstStats = await scanner.lastScanStats
    #expect(firstStats.filesParsed == 1)

    // Replace with something much shorter at the same path — a rotated or
    // truncated log, not an append.
    let smallLine = assistantLine(timestamp: now, messageID: "m", requestID: "r", input: 1, output: 1)
    try (smallLine + "\n").write(to: url, atomically: true, encoding: .utf8)
    #expect(try fixture.fileSize(url) < 900_000_000) // sanity: genuinely smaller

    let second = await scanner.scan(now: now)
    let secondStats = await scanner.lastScanStats

    #expect(secondStats.filesParsed == 1)
    // Only the new content counts — the old 1.8-billion-token line is gone,
    // not merged in as a stale leftover from the cache.
    #expect(second.points.first { $0.provider == .claude }?.totalTokens == 2)
}

@Test func aPartialTrailingLineIsNotLostOrDoubleCountedWhenItsRestArrives() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    let completeLine = assistantLine(timestamp: now, messageID: "msg_complete", requestID: "req_complete", input: 40, output: 4)
    let fullSecondLine = assistantLine(timestamp: now, messageID: "msg_partial", requestID: "req_partial", input: 60, output: 6)
    // Split mid-object, the way a writer's in-progress `write()` would leave
    // it on disk: no trailing newline yet.
    let splitPoint = fullSecondLine.index(fullSecondLine.startIndex, offsetBy: fullSecondLine.count / 2)
    let partialSecondLine = String(fullSecondLine[..<splitPoint])
    let restOfSecondLine = String(fullSecondLine[splitPoint...])

    let url = try fixture.writeClaudeSessionRaw(content: completeLine + "\n" + partialSecondLine)

    let scanner = fixture.scanner()
    let first = await scanner.scan(now: now)
    // The partial line must not be counted (it isn't valid JSON yet) and
    // must not be lost — only the complete first line shows up so far.
    #expect(first.points.first { $0.provider == .claude }?.totalTokens == 44)

    // The writer finishes the line it was in the middle of.
    try fixture.appendRaw(restOfSecondLine + "\n", to: url)

    let second = await scanner.scan(now: now)
    // Now complete, the second line is counted exactly once, on top of the
    // first — neither dropped nor double-counted.
    #expect(second.points.first { $0.provider == .claude }?.totalTokens == 44 + 66)
}

// MARK: - Disk-persisted cache

@Test func theCacheSurvivesARelaunchInsteadOfRescanningFromScratch() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    try fixture.writeClaudeSession(lines: [
        assistantLine(timestamp: now, messageID: "msg_relaunch", requestID: "req_relaunch", input: 30, output: 3)
    ])

    // First "launch": scans from nothing, then persists to disk.
    let first = await fixture.scanner().scan(now: now)

    // Second "launch": a brand-new actor, same on-disk cache directory —
    // this is what actually happens when the app quits and reopens.
    let relaunched = fixture.scanner()
    let second = await relaunched.scan(now: now)
    let secondStats = await relaunched.lastScanStats

    #expect(secondStats.filesParsed == 0)
    #expect(secondStats.filesCached == 1)
    #expect(secondStats.bytesRead == 0)
    #expect(second == first)
}

@Test func aCorruptCacheFileFallsBackToAFullRescanWithoutCrashing() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    try fixture.writeClaudeSession(lines: [
        assistantLine(timestamp: now, messageID: "msg_corrupt", requestID: "req_corrupt", input: 20, output: 2)
    ])

    // Simulate a half-written or bit-rotted cache file sitting where
    // `LocalUsageScanner` expects valid JSON.
    try FileManager.default.createDirectory(at: fixture.cacheDirectoryURL, withIntermediateDirectories: true)
    let cacheFile = fixture.cacheDirectoryURL
        .appendingPathComponent("local-usage-scan-cache.v\(LocalUsageScanner.cacheSchemaVersion).json")
    try Data("{ not valid json at all".utf8).write(to: cacheFile)

    let series = await fixture.scanner().scan(now: now)

    #expect(series.points.first { $0.provider == .claude }?.totalTokens == 22)
}

// MARK: - Prefilter safety

@Test func aLineWhoseJSONWouldCountIsNotSkippedByThePrefilter() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    // A realistic-shaped decoy: lots of conversation prose ahead of the
    // usage object, and deliberately free of the word "usage" itself, so a
    // pass only proves the filter keys on the real JSON field — not on
    // getting lucky with decoy text.
    let decoyProse = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 200)
    let claudeLine = #"""
        {"type":"assistant","timestamp":"\#(isoString(now))","requestId":"req_decoy","message":{"id":"msg_decoy","model":"claude-opus-5","content":[{"type":"text","text":"\#(decoyProse)"}],"usage":{"input_tokens":70,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":7}}}
        """#
    try fixture.writeClaudeSession(lines: [claudeLine])

    let codexTimestamp = isoString(now)
    let codexDecoyLine = #"""
        {"timestamp":"\#(codexTimestamp)","type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"\#(decoyProse)"}]}}
        """#
    try fixture.writeCodexSession(lines: [
        codexDecoyLine,
        #"{"timestamp":"\#(codexTimestamp)","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#,
        #"""
        {"timestamp":"\#(codexTimestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":8}}}}
        """#
    ])

    let series = await fixture.scanner().scan(now: now)

    #expect(series.points.first { $0.provider == .claude }?.totalTokens == 77)
    let codexPoint = try #require(series.points.first { $0.provider == .codex })
    #expect(codexPoint.totalTokens == 88)
    #expect(codexPoint.topModel == "gpt-5.6-terra")
}

// MARK: - Codex parsing

@Test func codexTokenCountDeltasAccumulateUnderTheTurnContextModel() async throws {
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()
    let timestamp = isoString(now)

    // Shape confirmed by inspecting real files under ~/.codex/sessions: the
    // model lives on `turn_context`, not on the `token_count` event itself,
    // and `cached_input_tokens` is a *subset* of `input_tokens` (unlike
    // Claude's additive cache fields) — input_tokens + output_tokens ==
    // total_tokens in every sampled event.
    try fixture.writeCodexSession(lines: [
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-terra"}}"#,
        #"""
        {"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"total_tokens":1050},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50,"total_tokens":1050}}}}
        """#
    ])

    let series = await fixture.scanner().scan(now: now)
    let point = try #require(series.points.first { $0.provider == .codex })

    // fresh input (1000 - 400 cached) + cached 400 + output 50 == 1050 total.
    #expect(point.totalTokens == 1_050)
    #expect(point.topModel == "gpt-5.6-terra")
}

// MARK: - Fixtures

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func assistantLine(
    timestamp: Date,
    messageID: String,
    requestID: String,
    input: Int,
    output: Int,
    model: String = "claude-opus-5"
) -> String {
    #"""
    {"type":"assistant","timestamp":"\#(isoString(timestamp))","requestId":"\#(requestID)","message":{"id":"\#(messageID)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":\#(output)}}}
    """#
}

private final class LocalUsageFixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    /// Passed straight to `LocalUsageScanner.init(claudeHomeURL:)`, which
    /// appends `.claude/projects` itself.
    var claudeHomeURL: URL { home.appendingPathComponent("claude-home", isDirectory: true) }

    /// Passed straight to `LocalUsageScanner.init(codexHomeURL:)`, which
    /// appends `sessions` / `archived_sessions` itself — this stands in for
    /// `~/.codex`, not `~`.
    var codexHomeURL: URL { home.appendingPathComponent("codex-home", isDirectory: true) }

    /// Passed straight to `LocalUsageScanner.init(cacheDirectoryURL:)` so a
    /// test never reads or writes the real `~/Library/Caches`.
    var cacheDirectoryURL: URL { home.appendingPathComponent("cache-home", isDirectory: true) }

    func scanner() -> LocalUsageScanner {
        LocalUsageScanner(claudeHomeURL: claudeHomeURL, codexHomeURL: codexHomeURL, cacheDirectoryURL: cacheDirectoryURL)
    }

    @discardableResult
    func writeClaudeSession(
        project: String = "-Users-test-project",
        sessionID: String = UUID().uuidString,
        lines: [String]
    ) throws -> URL {
        try writeClaudeSessionRaw(project: project, sessionID: sessionID, content: lines.joined(separator: "\n") + "\n")
    }

    /// No forced trailing newline — lets a test write a file that ends
    /// mid-line, the way a writer caught between two `write()` calls would
    /// leave it.
    @discardableResult
    func writeClaudeSessionRaw(
        project: String = "-Users-test-project",
        sessionID: String = UUID().uuidString,
        content: String
    ) throws -> URL {
        let dir = claudeHomeURL
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sessionID).jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Appends raw bytes to an existing file without touching what is
    /// already there — simulates a live CLI session still writing to the
    /// same path.
    func appendRaw(_ string: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(string.utf8))
    }

    func fileSize(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    @discardableResult
    func writeCodexSession(
        dateDir: String = "2026/08/13",
        sessionID: String = UUID().uuidString,
        lines: [String]
    ) throws -> URL {
        let dir = codexHomeURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(dateDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-\(sessionID).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@Test func dedupeSurvivesAResumeSoAReplayedMessageIsNotCountedTwice() async throws {
    // The shipped dedupe test only proved dedupe WITHIN one pass: it would
    // pass even if the seen-id set were thrown away between scans. This is the
    // case that actually happens — a resumed CLI session replays an assistant
    // message it already wrote, and the file is scanned incrementally, so the
    // ids must come back from the cache or every append re-admits duplicates.
    let fixture = try LocalUsageFixture()
    defer { fixture.remove() }
    let now = Date()

    let original = assistantLine(timestamp: now, messageID: "msg_a", requestID: "req_a", input: 1_000, output: 100)
    let url = try fixture.writeClaudeSession(lines: [original])

    let scanner = fixture.scanner()
    let first = await scanner.scan(now: now)
    #expect(first.points.first { $0.provider == .claude }?.totalTokens == 1_100)

    // The same message again, plus a genuinely new one.
    let fresh = assistantLine(timestamp: now, messageID: "msg_b", requestID: "req_b", input: 10, output: 1)
    try fixture.appendRaw(original + "\n" + fresh + "\n", to: url)

    let second = await scanner.scan(now: now)
    // 1100 + 11, NOT 1100 + 1100 + 11: the replay is recognised across the
    // resume boundary, where the offset means those bytes are seen fresh.
    #expect(second.points.first { $0.provider == .claude }?.totalTokens == 1_111)

    // And across a relaunch, where the ids can only come from the persisted
    // cache rather than from memory.
    let relaunched = fixture.scanner()
    let third = await relaunched.scan(now: now)
    #expect(third.points.first { $0.provider == .claude }?.totalTokens == 1_111)
}
