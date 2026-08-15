import Foundation

/// The two agents Vibenotch already watches. Deliberately not a general
/// provider registry: the app that inspired this supports thirty-odd services
/// and pays for it in surface area we would gain nothing from.
enum UsageProviderKind: String, Sendable, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Which bucket a window is, decided by how long it lasts.
///
/// This is the whole reason the type exists. Both APIs name their slots by
/// position rather than by meaning — OpenAI returns `primary_window` and
/// `secondary_window` — and on a real account here the *primary* window was the
/// seven-day one with `secondary_window` null. Trusting the slot name would
/// print "Session" over a weekly quota. The duration never lies.
enum UsageWindowKind: Sendable, Equatable {
    case session
    case weekly

    /// Twelve hours splits the two cleanly: session windows observed so far are
    /// five hours, weekly ones are 604800 seconds. Anything long is treated as
    /// weekly rather than guessed at.
    static func classify(lengthSeconds: TimeInterval?) -> UsageWindowKind {
        guard let lengthSeconds, lengthSeconds > 0 else { return .session }
        return lengthSeconds <= 12 * 3600 ? .session : .weekly
    }
}

/// How close to the edge, as the service itself judges it where it says so.
///
/// Claude returns this per limit; OpenAI does not, so it is derived there. The
/// two must stay comparable, because the notch shows one badge for the worst
/// of everything.
enum UsageSeverity: String, Sendable, Comparable {
    case normal
    case warning
    case critical

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The fallback for a service that does not grade its own limits.
    static func derived(fromPercentUsed percent: Double) -> UsageSeverity {
        switch percent {
        case ..<75: .normal
        case ..<90: .warning
        default: .critical
        }
    }
}

/// One quota bucket at one moment.
struct UsageWindow: Sendable, Equatable, Identifiable {
    let kind: UsageWindowKind
    /// 0...100. Percent USED, not left — every API here reports it that way,
    /// and flipping it at the edges is how off-by-one-hundred bugs happen. The
    /// UI does the subtraction once, at the point of display.
    let percentUsed: Double
    let resetsAt: Date?
    let windowLength: TimeInterval?
    /// Set when the limit applies to one model rather than the whole account,
    /// e.g. a weekly cap scoped to a single model. nil means account-wide.
    let scopeLabel: String?
    let severity: UsageSeverity

    var id: String {
        "\(kind)-\(scopeLabel ?? "account")"
    }

    var percentLeft: Double {
        max(0, 100 - percentUsed)
    }

    /// The constructor for anything coming off the wire. Returns nil when the
    /// percentage is not a percentage.
    ///
    /// A separate factory rather than a failable init so that constructing a
    /// window from values already known to be good — a preview, a test — stays
    /// a plain expression. The rule it enforces is the one the rest of this
    /// layer already follows: a value we cannot believe produces an ABSENT
    /// window, never a shown one. Without it a service answering `120` drew a
    /// bar reading "120% used" and sent that number on to the phone.
    static func validated(
        kind: UsageWindowKind,
        percentUsed: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        scopeLabel: String?,
        severity: UsageSeverity
    ) -> UsageWindow? {
        guard percentUsed.isFinite, (0...100).contains(percentUsed) else { return nil }
        return UsageWindow(
            kind: kind,
            percentUsed: percentUsed,
            resetsAt: resetsAt,
            windowLength: windowLength,
            scopeLabel: scopeLabel,
            severity: severity
        )
    }
}

/// Where the user should be if they were spending evenly, and what that implies.
///
/// Filled by the pace engine, which is the part that turns a number into a
/// decision: 84% used means nothing until you know whether it is day two or
/// day six of the window.
struct UsagePace: Sendable, Equatable {
    /// Percent that even spending would have consumed by now.
    let expectedPercent: Double
    /// actual − expected. Positive means burning faster than the window allows.
    let deltaPercent: Double
    /// When the quota is projected to hit 100%, or nil if it lasts to the reset.
    let runsOutAt: Date?

    var willLastToReset: Bool { runsOutAt == nil }
}

/// How this account is paid for, which decides whether money is a sensible
/// thing to show at all.
///
/// On a subscription there is no per-token charge, so a dollar figure could
/// only be invented from published API rates and then shown next to usage the
/// user did not pay for. Tokens are the exact quantity; money is not our
/// number to state. Both accounts here are subscriptions, so the `apiKey` case
/// is recorded rather than acted on — it exists so the distinction is in the
/// model instead of in someone's head.
enum UsageBilling: Sendable, Equatable {
    case plan(String?)
    case apiKey

    var isSubscription: Bool {
        if case .plan = self { return true }
        return false
    }
}

/// Everything one provider can tell us in one poll.
struct UsageSnapshot: Sendable, Equatable {
    let provider: UsageProviderKind
    let account: String?
    let plan: String?
    let billing: UsageBilling
    let windows: [UsageWindow]
    let capturedAt: Date

    /// The single worst thing happening, for the notch badge.
    var worstSeverity: UsageSeverity {
        windows.map(\.severity).max() ?? .normal
    }

    func window(_ kind: UsageWindowKind) -> UsageWindow? {
        // Account-wide first: a model-scoped cap is extra detail, never the
        // headline, or one busy model would misreport the whole account.
        windows.first { $0.kind == kind && $0.scopeLabel == nil }
            ?? windows.first { $0.kind == kind }
    }
}

/// Why a provider has nothing to show.
///
/// A distinct case per cause because the answer differs: an expired login is
/// fixed by the user running the CLI, a changed response is our problem, and a
/// flaky network is nobody's. The UI must never render any of them as 0%.
enum UsageUnavailable: Error, Sendable, Equatable {
    case notLoggedIn
    case credentialExpired
    case network(String)
    case unexpectedResponse(String)
}

protocol UsageFetching: Sendable {
    var kind: UsageProviderKind { get }
    func fetch(now: Date) async throws -> UsageSnapshot
}
