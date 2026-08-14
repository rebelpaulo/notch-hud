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
        percentString(percent, wordKey: "%d%% used", underOneKey: "<1% used")
    }

    /// "16% left" — same rounding rule as `percentUsed`, mirrored.
    static func percentLeft(_ percent: Double) -> String {
        percentString(percent, wordKey: "%d%% left", underOneKey: "<1% left")
    }

    private static func percentString(_ percent: Double, wordKey: String, underOneKey: String) -> String {
        if percent > 0, percent < 1 { return t(underOneKey) }
        return t(wordKey, Int(percent.rounded()))
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

    /// "On pace" / "Ahead of pace" / "Behind pace". The ±5 point band is a
    /// noise floor — a delta of 1 or 2 is measurement jitter, not a trend
    /// worth alarming the user about.
    static func pacePhrase(_ pace: UsagePace) -> String {
        if pace.deltaPercent > 5 { return t("Ahead of pace") }
        if pace.deltaPercent < -5 { return t("Behind pace") }
        return t("On pace")
    }

    /// "Lasts until reset" or "Runs out in <duration>", the right-column
    /// counterpart to `pacePhrase`.
    static func projectionPhrase(_ pace: UsagePace, now: Date) -> String {
        guard let runsOutAt = pace.runsOutAt else { return t("Lasts until reset") }
        return runsOut(at: runsOutAt, from: now)
    }
}

extension UsageFormatting {
    /// Token counts run to billions here, so a raw integer is a wall of
    /// digits nobody parses at a glance. One decimal below ten so 1.4B and
    /// 9.8B stay distinguishable; none above, where the extra digit is noise.
    static func tokenCount(_ tokens: Int) -> String {
        let value = Double(tokens)
        switch value {
        case 1e9...:
            return compact(value / 1e9, suffix: "B")
        case 1e6...:
            return compact(value / 1e6, suffix: "M")
        case 1e3...:
            return compact(value / 1e3, suffix: "K")
        default:
            return "\(tokens)"
        }
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let text = value < 10
            ? String(format: "%.1f", value)
            : String(format: "%.0f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
}
