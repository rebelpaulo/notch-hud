import Foundation

/// Turns a raw `UsageWindow` into a judgment: are we burning this quota
/// faster than the window allows, and if so, when does it run dry.
///
/// Pure and stateless on purpose — no state beyond the two nominal-length
/// constants below, no internal clock. `now` always arrives as a parameter so
/// every answer is reproducible in a test and nothing here can race a poll.
struct UsagePaceEngine: Sendable {
    /// Claude's `resets_at` never comes with a window length — unlike Codex,
    /// which sends `limit_window_seconds` on every response. These two
    /// numbers are our own assumption about the shape of Anthropic's plans
    /// (a 5-hour session window, a 7-day weekly one), not something any
    /// response body told us. If Anthropic resizes a window, this is the
    /// line that goes wrong, and it should be easy to find and fix.
    static let nominalSessionLength: TimeInterval = 5 * 3_600
    static let nominalWeeklyLength: TimeInterval = 7 * 24 * 3_600

    /// - Returns: `nil` when there isn't enough information to place `window`
    ///   on a timeline at all. The UI's response to `nil` is to draw no pace
    ///   marker — silence is the honest answer when we can't know.
    func pace(for window: UsageWindow, now: Date) -> UsagePace? {
        // No reset date: there is no window to measure a position inside.
        guard let resetsAt = window.resetsAt else { return nil }

        // Prefer the real length when the API sent one (Codex does); fall
        // back to the nominal length implied by the window's kind (Claude
        // always needs this). `??` alone was not enough: it only falls back
        // when the reported length is NIL, so a service answering
        // `limit_window_seconds: 0` produced a zero length, failed the
        // positivity check, and returned no pace at all — even though the
        // nominal fallback was sitting right there and usable. A reported
        // length has to be positive to be preferred; otherwise it is no
        // better than a missing one.
        //
        // The guard still fails safe rather than force-unwrapping: both of
        // today's kinds have a nominal length, but a future kind without one
        // should lose its pace, not crash.
        let reported = window.windowLength.flatMap { $0 > 0 ? $0 : nil }
        guard let length = reported ?? nominalLength(for: window.kind), length > 0 else {
            return nil
        }

        let windowStart = resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(windowStart)

        // elapsed <= 0 means `now` is still before the window even started
        // by this math — resetsAt is more than a full window away. That's
        // clock skew or a stale/misreported reset date, not a window we can
        // report a fractional position inside. Also guards the division
        // below from ever seeing a non-positive denominator indirectly.
        guard elapsed > 0 else { return nil }

        // elapsed >= length means the reset this window promised has
        // already passed relative to `now` — the snapshot is stale (fetched
        // before a reset that has since happened). Nothing here can be
        // trusted as "where we are in the current window."
        guard elapsed < length else { return nil }

        let fraction = elapsed / length
        let expectedPercent = min(100, max(0, fraction * 100))
        let deltaPercent = window.percentUsed - expectedPercent

        return UsagePace(
            expectedPercent: expectedPercent,
            deltaPercent: deltaPercent,
            runsOutAt: projectedRunOut(window: window, elapsed: elapsed, now: now, resetsAt: resetsAt)
        )
    }

    private func nominalLength(for kind: UsageWindowKind) -> TimeInterval? {
        switch kind {
        case .session: Self.nominalSessionLength
        case .weekly: Self.nominalWeeklyLength
        }
    }

    /// Extrapolates the observed burn rate (`percentUsed` over `elapsed`)
    /// forward to find the moment it would cross 100%.
    private func projectedRunOut(window: UsageWindow, elapsed: TimeInterval, now: Date, resetsAt: Date) -> Date? {
        let percentUsed = window.percentUsed

        if percentUsed <= 0 {
            // Zero spent so far means a zero burn rate. Extrapolating a rate
            // of zero forward never reaches 100% — it's not a division by
            // zero to dodge, it's a genuine "this never runs out" answer.
            return nil
        }

        if percentUsed >= 100 {
            // Already over. We don't know the exact instant it crossed
            // 100 — the snapshot only tells us it's true as of `now` — so
            // `now` is the most honest value to report. It also keeps the
            // "runs out strictly before resetsAt" invariant, since the
            // elapsed < length guard above already puts `now` before
            // resetsAt.
            return now
        }

        let ratePerSecond = percentUsed / elapsed
        let secondsToFull = (100 - percentUsed) / ratePerSecond
        let projected = now.addingTimeInterval(secondsToFull)

        // If the projection lands at or after the reset, the quota lasts to
        // the reset — that isn't a "runs out" moment at all.
        return projected < resetsAt ? projected : nil
    }
}
