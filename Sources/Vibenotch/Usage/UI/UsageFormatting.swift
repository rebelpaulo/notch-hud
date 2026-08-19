import Foundation

/// Text formatting for the usage card. Kept apart from the views so it can be
/// unit tested without SwiftUI, and apart from `UsageModels` because these are
/// presentation choices (how many units, when to say "just now"), not facts
/// about a quota.
enum UsageFormatting {
    /// "2h 53m", "5d 4h", "45m" — the largest two non-second units, no
    /// zero-padding. Seconds never appear: at the resolution this UI polls,
    /// showing them would just be noise that reflows every tick.
    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// "Resets in 5d 4h". A window whose reset has already passed (or has no
    /// reset date at all) is a stale snapshot, not a negative countdown, so it
    /// gets its own phrase instead of "-3m".
    static func countdown(to date: Date?, from now: Date) -> String {
        guard let date, date.timeIntervalSince(now) > 0 else { return t("Resetting…") }
        return t("Resets in %@", duration(date.timeIntervalSince(now)))
    }

    /// "Runs out in 5d 4h" — same past-date guard as `countdown`, since a
    /// pace projection can't land before the window it is projecting inside.
    static func runsOut(at date: Date, from now: Date) -> String {
        guard date.timeIntervalSince(now) > 0 else { return t("Resetting…") }
        return t("Runs out in %@", duration(date.timeIntervalSince(now)))
    }

    /// "84% used". Below one point rounds to "<1% used" rather than "0%",
    /// because those are different facts — one is "nothing spent yet", the
    /// other is "a sliver was".
    static func percentUsed(_ percent: Double) -> String {
        percentString(
            percent,
            singularKey: "1% used",
            pluralKey: "%d%% used",
            underOneKey: "<1% used"
        )
    }

    /// "16% left" — same rounding rule as `percentUsed`, mirrored.
    static func percentLeft(_ percent: Double) -> String {
        percentString(
            percent,
            singularKey: "1% left",
            pluralKey: "%d%% left",
            underOneKey: "<1% left"
        )
    }

    private static func percentString(
        _ percent: Double,
        singularKey: String,
        pluralKey: String,
        underOneKey: String
    ) -> String {
        if percent > 0, percent < 1 { return t(underOneKey) }
        let rounded = Int(percent.rounded())
        return rounded == 1 ? t(singularKey) : t(pluralKey, rounded)
    }

    /// "updated just now" / "updated 3m ago". Single largest unit only —
    /// this is a glance at freshness, not a countdown, so "2h 53m ago" would
    /// be more precision than the label needs.
    static func relativeUpdated(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return t("updated just now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return t("updated %dm ago", minutes) }
        let hours = Int(seconds / 3_600)
        if hours < 24 { return t("updated %dh ago", hours) }
        return t("updated %dd ago", Int(seconds / 86_400))
    }

    /// Points of pace drift treated as noise rather than a real lead or lag.
    /// This is the ONE place that number lives: both `pacePhrase` (the
    /// words) and `UsageGauge`'s marker color are the same "ahead of pace?"
    /// judgement rendered twice — through this one threshold — so the two
    /// can never disagree on the same row again.
    static let paceNoiseFloor: Double = 5

    /// Whether a delta is far enough past the noise floor to read as ahead
    /// of pace — the same judgement `pacePhrase` turns into words, exposed
    /// as a plain yes/no for `UsageGauge`'s marker color to key off of.
    static func isAheadOfPace(_ pace: UsagePace) -> Bool {
        pace.deltaPercent > paceNoiseFloor
    }

    /// "On pace" / "Ahead of pace" / "Behind pace". The ±5 point band is a
    /// noise floor — a delta of 1 or 2 is measurement jitter, not a trend
    /// worth alarming the user about.
    static func pacePhrase(_ pace: UsagePace) -> String {
        if isAheadOfPace(pace) { return t("Ahead of pace") }
        if pace.deltaPercent < -paceNoiseFloor { return t("Behind pace") }
        return t("On pace")
    }

    /// "Lasts until reset" or "Runs out in <duration>", the right-column
    /// counterpart to `pacePhrase`.
    static func projectionPhrase(_ pace: UsagePace, now: Date) -> String {
        guard let runsOutAt = pace.runsOutAt else { return t("Lasts until reset") }
        return runsOut(at: runsOutAt, from: now)
    }

    /// One-shot resets only earn a row when the account can use one. Zero is
    /// a valid API value, but showing "0 available" on accounts that never
    /// receive this capability turns absence into persistent visual noise.
    static func limitResetCredits(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1
            ? t("1 limit reset available")
            : t("%d limit resets available", count)
    }
}

extension UsageFormatting {
    /// Token counts run to billions here, so a raw integer is a wall of
    /// digits nobody parses at a glance. One decimal below ten so 1.4B and
    /// 9.8B stay distinguishable; none above, where the extra digit is noise.
    static func tokenCount(_ tokens: Int) -> String {
        let value = Double(tokens)
        // Ordered largest-first so the first divisor the raw value clears
        // wins, same as the old switch — but the suffix isn't final until
        // we check what it will actually *print*: rounding a value like
        // 999_999 up at the K tier prints "1000K", which is really 1M's
        // territory, so a "1000" print bumps to the next suffix up.
        let tiers: [(divisor: Double, suffix: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (index, tier) in tiers.enumerated() where value >= tier.divisor {
            let printed = compact(value / tier.divisor, suffix: tier.suffix)
            guard printed.hasPrefix("1000"), index > 0 else { return printed }
            let next = tiers[index - 1]
            return compact(value / next.divisor, suffix: next.suffix)
        }
        return "\(tokens)"
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let text = value < 10
            ? String(format: "%.1f", value)
            : String(format: "%.0f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
}
