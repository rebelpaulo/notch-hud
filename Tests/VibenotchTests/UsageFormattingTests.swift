import Foundation
import Testing
@testable import Vibenotch

@Suite("Usage formatting")
struct UsageFormattingTests {
    // MARK: duration

    @Test func durationShowsTheLargestTwoUnits() {
        #expect(UsageFormatting.duration(2 * 3_600 + 53 * 60) == "2h 53m")
        #expect(UsageFormatting.duration(5 * 86_400 + 4 * 3_600) == "5d 4h")
        #expect(UsageFormatting.duration(28 * 86_400 + 2 * 3_600) == "28d 2h")
        #expect(UsageFormatting.duration(45 * 60) == "45m")
    }

    @Test func durationDropsSecondsAndNeverZeroPads() {
        // 59 seconds rounds down to 0 minutes, not "0m" with a leading pad
        // and not a fractional minute.
        #expect(UsageFormatting.duration(59) == "0m")
        // A third unit (minutes, once days is the leading unit) is dropped
        // entirely rather than shown as "5d 4h 0m".
        #expect(UsageFormatting.duration(5 * 86_400 + 4 * 3_600 + 30 * 60) == "5d 4h")
        #expect(UsageFormatting.duration(0) == "0m")
    }

    // MARK: countdown / runsOut

    @Test func countdownFormatsAFutureReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resetsAt = now.addingTimeInterval(2 * 3_600 + 53 * 60)
        #expect(UsageFormatting.countdown(to: resetsAt, from: now) == "Resets in 2h 53m")
    }

    @Test func countdownReadsAsResettingOncePastOrMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageFormatting.countdown(to: now, from: now) == "Resetting…")
        #expect(UsageFormatting.countdown(to: now.addingTimeInterval(-1), from: now) == "Resetting…")
        #expect(UsageFormatting.countdown(to: nil, from: now) == "Resetting…")
    }

    @Test func runsOutFormatsAFutureProjection() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let runsOutAt = now.addingTimeInterval(5 * 86_400 + 4 * 3_600)
        #expect(UsageFormatting.runsOut(at: runsOutAt, from: now) == "Runs out in 5d 4h")
    }

    @Test func runsOutReadsAsResettingOncePast() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageFormatting.runsOut(at: now.addingTimeInterval(-60), from: now) == "Resetting…")
    }

    // MARK: percent

    @Test func percentUsedIsAnIntegerWithAWordBelowOnePoint() {
        #expect(UsageFormatting.percentUsed(84) == "84% used")
        #expect(UsageFormatting.percentUsed(84.6) == "85% used")
        #expect(UsageFormatting.percentUsed(0) == "0% used")
        #expect(UsageFormatting.percentUsed(100) == "100% used")
        #expect(UsageFormatting.percentUsed(0.4) == "<1% used")
    }

    @Test func percentLeftIsAnIntegerWithAWordBelowOnePoint() {
        #expect(UsageFormatting.percentLeft(16) == "16% left")
        #expect(UsageFormatting.percentLeft(0) == "0% left")
        #expect(UsageFormatting.percentLeft(100) == "100% left")
        #expect(UsageFormatting.percentLeft(0.9) == "<1% left")
    }

    // MARK: relative "updated"

    @Test func relativeUpdatedStepsThroughUnits() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageFormatting.relativeUpdated(now, now: now) == "updated just now")
        #expect(UsageFormatting.relativeUpdated(now.addingTimeInterval(-59), now: now) == "updated just now")
        #expect(UsageFormatting.relativeUpdated(now.addingTimeInterval(-3 * 60), now: now) == "updated 3m ago")
        #expect(UsageFormatting.relativeUpdated(now.addingTimeInterval(-2 * 3_600), now: now) == "updated 2h ago")
        #expect(UsageFormatting.relativeUpdated(now.addingTimeInterval(-3 * 86_400), now: now) == "updated 3d ago")
    }

    // MARK: pace phrase — boundaries at exactly ±5

    @Test func pacePhraseBoundaries() {
        #expect(UsageFormatting.pacePhrase(UsagePace(expectedPercent: 50, deltaPercent: 5, runsOutAt: nil)) == "On pace")
        #expect(UsageFormatting.pacePhrase(UsagePace(expectedPercent: 50, deltaPercent: -5, runsOutAt: nil)) == "On pace")
        #expect(UsageFormatting.pacePhrase(UsagePace(expectedPercent: 50, deltaPercent: 5.1, runsOutAt: nil)) == "Ahead of pace")
        #expect(UsageFormatting.pacePhrase(UsagePace(expectedPercent: 50, deltaPercent: -5.1, runsOutAt: nil)) == "Behind pace")
        #expect(UsageFormatting.pacePhrase(UsagePace(expectedPercent: 50, deltaPercent: 0, runsOutAt: nil)) == "On pace")
    }

    // MARK: projection phrase

    @Test func projectionPhraseLastsUntilResetWhenNoRunsOutDate() {
        let pace = UsagePace(expectedPercent: 50, deltaPercent: -5, runsOutAt: nil)
        #expect(pace.willLastToReset)
        #expect(UsageFormatting.projectionPhrase(pace, now: Date()) == "Lasts until reset")
    }

    @Test func projectionPhraseRunsOutWhenProjected() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pace = UsagePace(
            expectedPercent: 55,
            deltaPercent: 29,
            runsOutAt: now.addingTimeInterval(5 * 3_600 + 4 * 60)
        )
        #expect(!pace.willLastToReset)
        #expect(UsageFormatting.projectionPhrase(pace, now: now) == "Runs out in 5h 4m")
    }
}

@Test func tokenCountsCompactWithoutLosingTheDistinctionBetweenBillions() {
    #expect(UsageFormatting.tokenCount(0) == "0")
    #expect(UsageFormatting.tokenCount(999) == "999")
    #expect(UsageFormatting.tokenCount(1_500) == "1.5K")
    #expect(UsageFormatting.tokenCount(85_000_000) == "85M")
    // The two that must not collapse into each other: this account really
    // does run to billions, and "16B" vs "1.6B" is an order of magnitude.
    #expect(UsageFormatting.tokenCount(1_600_000_000) == "1.6B")
    #expect(UsageFormatting.tokenCount(16_100_000_000) == "16B")
    // A whole number keeps no pointless decimal.
    #expect(UsageFormatting.tokenCount(2_000_000) == "2M")
}

// DEFECT 1: the suffix must be chosen against the value as it will actually
// be printed, not the raw value — otherwise rounding pushes a number like
// 999_999 into "1000K" instead of bumping it to the next suffix.
@Test func tokenCountNeverPrintsAThousandOfTheCurrentSuffix() {
    #expect(UsageFormatting.tokenCount(999_999) == "1M")
    #expect(UsageFormatting.tokenCount(1_000_000) == "1M")
    #expect(UsageFormatting.tokenCount(999_999_999) == "1B")
    #expect(UsageFormatting.tokenCount(1_000_000_000) == "1B")
}

// DEFECT 2: the gauge marker's color and `pacePhrase`'s words must be driven
// by the same judgement so they can never disagree on the same row.
@Test func paceJudgementUsedByTheGaugeMarkerAgreesWithThePhraseBoundary() {
    let justOverOnPace = UsagePace(expectedPercent: 50, deltaPercent: 1, runsOutAt: nil)
    let clearlyAhead = UsagePace(expectedPercent: 50, deltaPercent: 6, runsOutAt: nil)
    #expect(UsageFormatting.pacePhrase(justOverOnPace) == "On pace")
    #expect(!UsageFormatting.isAheadOfPace(justOverOnPace))
    #expect(UsageFormatting.pacePhrase(clearlyAhead) == "Ahead of pace")
    #expect(UsageFormatting.isAheadOfPace(clearlyAhead))
}

// DEFECT 3: "%d%% left"/"%d%% used" print for values above one, so the PT
// adjective needs plural agreement — "restante"/"usado" read as singular.
@Test func portugueseQuotaPercentStringsAgreeInNumber() throws {
    let url = try #require(
        Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "pt.lproj")
    )
    let contents = try Data(contentsOf: url)
    let table = try #require(
        PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: String]
    )
    #expect(table["%d%% left"] == "%d%% restantes")
    #expect(table["%d%% used"] == "%d%% usados")
}
