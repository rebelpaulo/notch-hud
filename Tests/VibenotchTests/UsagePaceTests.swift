import Foundation
import Testing
@testable import Vibenotch

@Suite("UsagePaceEngine")
struct UsagePaceEngineTests {
    let engine = UsagePaceEngine()
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func window(
        kind: UsageWindowKind = .weekly,
        percentUsed: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?
    ) -> UsageWindow {
        UsageWindow(
            kind: kind,
            percentUsed: percentUsed,
            resetsAt: resetsAt,
            windowLength: windowLength,
            scopeLabel: nil,
            severity: .derived(fromPercentUsed: percentUsed)
        )
    }

    // MARK: - Dead-on / ahead / behind

    @Test("dead-on pace has ~zero delta")
    func deadOnPace() throws {
        // 2 days into a 7-day window: fraction = 2/7 -> expectedPercent ≈ 28.571.
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(5 * 24 * 3_600)
        let w = window(percentUsed: 200.0 / 7.0, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(abs(pace.deltaPercent) < 0.0001)
    }

    @Test("spending faster than the window elapsed gives a positive delta")
    func aheadOfPace() throws {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(5 * 24 * 3_600) // 2 days elapsed
        let w = window(percentUsed: 80, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(pace.deltaPercent > 0)
    }

    @Test("spending slower than the window elapsed gives a negative delta")
    func behindPace() throws {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(1 * 24 * 3_600) // 6 days elapsed
        let w = window(percentUsed: 10, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(pace.deltaPercent < 0)
    }

    // MARK: - Run-out projection

    @Test("a window burning fast projects a runsOutAt strictly before resetsAt")
    func projectsRunOutBeforeReset() throws {
        let length: TimeInterval = 5 * 3_600
        let resetsAt = now.addingTimeInterval(4 * 3_600) // 1h elapsed of a 5h window
        let w = window(kind: .session, percentUsed: 90, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        let runsOutAt = try #require(pace.runsOutAt)
        #expect(runsOutAt < resetsAt)
        #expect(runsOutAt > now)
        #expect(!pace.willLastToReset)
    }

    @Test("a window burning slowly lasts to the reset: runsOutAt is nil")
    func lastsToReset() throws {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(6 * 24 * 3_600) // 1 day elapsed
        let w = window(percentUsed: 5, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(pace.runsOutAt == nil)
        #expect(pace.willLastToReset)
    }

    // MARK: - Edge cases that must be decided, not stumbled into

    @Test("no resetsAt: nil, nothing to place on a timeline")
    func nilResetsAt() {
        let w = window(percentUsed: 50, resetsAt: nil, windowLength: 7 * 24 * 3_600)
        #expect(engine.pace(for: w, now: now) == nil)
    }

    @Test("elapsed <= 0 (reset further out than a full window): nil, no divide by zero")
    func elapsedNotPositive() {
        let length: TimeInterval = 7 * 24 * 3_600
        // resetsAt is 8 days out, one more day than the window is long, so
        // windowStart (resetsAt - length) is still a day in the future.
        let resetsAt = now.addingTimeInterval(8 * 24 * 3_600)
        let w = window(percentUsed: 10, resetsAt: resetsAt, windowLength: length)
        #expect(engine.pace(for: w, now: now) == nil)
    }

    @Test("elapsed exactly 0 at windowStart: nil, not a division by zero")
    func elapsedExactlyZero() {
        let length: TimeInterval = 7 * 24 * 3_600
        // windowStart == now precisely: resetsAt is exactly one window away.
        let resetsAt = now.addingTimeInterval(length)
        let w = window(percentUsed: 10, resetsAt: resetsAt, windowLength: length)
        #expect(engine.pace(for: w, now: now) == nil)
    }

    @Test("elapsed >= windowLength (resetsAt already in the past): nil, stale snapshot")
    func elapsedPastWindowLength() {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(-3_600) // reset was an hour ago
        let w = window(percentUsed: 50, resetsAt: resetsAt, windowLength: length)
        #expect(engine.pace(for: w, now: now) == nil)
    }

    @Test("percentUsed is 0 with time elapsed: zero burn rate, runsOutAt nil, not a crash")
    func zeroPercentUsed() throws {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(5 * 24 * 3_600) // 2 days elapsed
        let w = window(percentUsed: 0, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(pace.runsOutAt == nil)
        #expect(pace.willLastToReset)
        // expectedPercent/deltaPercent are still meaningful even at 0% used.
        #expect(pace.deltaPercent < 0)
    }

    @Test("percentUsed >= 100 already: runsOutAt is now, strictly before resetsAt")
    func alreadyExhausted() throws {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(5 * 24 * 3_600) // 2 days elapsed
        let w = window(percentUsed: 100, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(pace.runsOutAt == now)
        let runsOutAt = try #require(pace.runsOutAt)
        #expect(runsOutAt < resetsAt)
    }

    @Test("percentUsed over 100 (overshoot): still runsOutAt == now, not a crash")
    func overExhausted() throws {
        let length: TimeInterval = 7 * 24 * 3_600
        let resetsAt = now.addingTimeInterval(5 * 24 * 3_600)
        let w = window(percentUsed: 123, resetsAt: resetsAt, windowLength: length)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(pace.runsOutAt == now)
    }

    // MARK: - Window length source

    @Test("Codex-style explicit windowLength is preferred over the nominal fallback")
    func explicitWindowLengthPreferred() throws {
        // A session-kind window (nominal 5h) that actually reports a 3h
        // length via limit_window_seconds. If the engine used the nominal
        // fallback instead, the fraction (and thus the delta) would differ.
        let explicitLength: TimeInterval = 3 * 3_600
        let resetsAt = now.addingTimeInterval(2 * 3_600) // 1h elapsed of 3h
        let w = window(kind: .session, percentUsed: 50, resetsAt: resetsAt, windowLength: explicitLength)
        let pace = try #require(engine.pace(for: w, now: now))
        // fraction = 1/3 -> expectedPercent ≈ 33.333, not 1/5 * 100 = 20.
        #expect(abs(pace.expectedPercent - 100.0 / 3.0) < 0.0001)
    }

    @Test("Claude-style nil windowLength falls back to the nominal length for .session")
    func nominalSessionFallback() throws {
        let resetsAt = now.addingTimeInterval(4 * 3_600) // 1h elapsed of nominal 5h
        let w = window(kind: .session, percentUsed: 50, resetsAt: resetsAt, windowLength: nil)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(abs(pace.expectedPercent - 20.0) < 0.0001) // 1h / 5h = 20%
    }

    @Test("Claude-style nil windowLength falls back to the nominal length for .weekly")
    func nominalWeeklyFallback() throws {
        let resetsAt = now.addingTimeInterval(6 * 24 * 3_600) // 1 day elapsed of nominal 7 days
        let w = window(kind: .weekly, percentUsed: 50, resetsAt: resetsAt, windowLength: nil)
        let pace = try #require(engine.pace(for: w, now: now))
        #expect(abs(pace.expectedPercent - (100.0 / 7.0)) < 0.0001)
    }

    // MARK: - The real account this ticket was written from

    @Test("real account: 7-day Claude window, 84% used, reset 4d17h away")
    func realAccountSevenDayEightyFourPercent() throws {
        // windowLength = nominal 7 days (Claude sends no length at all).
        // elapsed = 604_800 - (4d17h = 406_800s) = 198_000s.
        // fraction = 198_000 / 604_800 = 55/168 ≈ 0.32738095238095238
        // expectedPercent = 55/168 * 100 ≈ 32.738095238095234
        // deltaPercent = 84 - expectedPercent ≈ 51.261904761904766
        //
        // Burn rate = 84 / 198_000 %/s. Seconds to 100% = 16 / rate
        //           = 16 * 198_000 / 84 = 264_000 / 7 ≈ 37_714.285714285714s
        //           ≈ 10h 28m 34s from now — well inside the 4d17h left on
        //           the reset, so this is a real projected runsOutAt, not nil.
        let resetsAt = now.addingTimeInterval(4 * 24 * 3_600 + 17 * 3_600)
        let w = window(kind: .weekly, percentUsed: 84, resetsAt: resetsAt, windowLength: nil)

        let pace = try #require(engine.pace(for: w, now: now))

        #expect(abs(pace.expectedPercent - 32.738095238095234) < 0.0001)
        #expect(abs(pace.deltaPercent - 51.261904761904766) < 0.0001)

        let runsOutAt = try #require(pace.runsOutAt)
        let secondsToFull = 264_000.0 / 7.0
        #expect(abs(runsOutAt.timeIntervalSince(now) - secondsToFull) < 0.001)
        #expect(runsOutAt < resetsAt)

        // In human terms: burning at this rate, the weekly quota is
        // projected to run out in roughly 10.5 hours, days before the
        // 4-day-17-hour reset actually arrives. That is "ahead of pace" by
        // over 51 points and a real runsOutAt, not "lasts until reset."
    }
}

@Test func aZeroReportedWindowLengthFallsBackToTheNominalOne() {
    // `??` only falls back on nil, so a service answering
    // `limit_window_seconds: 0` used to discard a perfectly good nominal
    // length and return no pace at all.
    let engine = UsagePaceEngine()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let weekly = UsageWindow(
        kind: .weekly,
        percentUsed: 50,
        resetsAt: now.addingTimeInterval(3.5 * 24 * 3600),
        windowLength: 0,
        scopeLabel: nil,
        severity: .normal
    )

    let pace = engine.pace(for: weekly, now: now)
    #expect(pace != nil)
    // Half of a nominal seven-day window has elapsed.
    #expect(abs((pace?.expectedPercent ?? 0) - 50) < 0.5)
}
