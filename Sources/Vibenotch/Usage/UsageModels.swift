import Foundation

/// The three agents Vibenotch already watches. Deliberately not a general
/// provider registry: the app that inspired this supports thirty-odd services
/// and pays for it in surface area we would gain nothing from.
enum UsageProviderKind: String, Sendable, CaseIterable {
    case claude
    case codex
    case grok

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
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
    ///
    /// Returns nil when there is nothing to classify from — a missing or
    /// non-positive length must not become a guess. `limit_window_seconds` is
    /// the only signal Codex windows carry; losing it must lose the window,
    /// not silently relabel a weekly quota as a five-hour session (which then
    /// feeds a wrong projection into the pace engine).
    static func classify(lengthSeconds: TimeInterval?) -> UsageWindowKind? {
        guard let lengthSeconds, lengthSeconds > 0 else { return nil }
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
    private let identityOrdinal: Int

    /// Reset metadata is deliberately absent: APIs can add, remove, or adjust
    /// it between polls without changing which quota row the user is looking
    /// at. Snapshot assembly adds an ordinal only when kind and scope are not
    /// enough to distinguish multiple rows.
    var id: String {
        identityOrdinal == 0 ? identityBase : "\(identityBase)#\(identityOrdinal + 1)"
    }

    fileprivate var identityBase: String {
        let kindID = kind == .session ? "session" : "weekly"
        guard let scopeLabel else { return "\(kindID)-account" }
        // The byte count keeps a real scope named "account" and labels that
        // contain our separators from ever aliasing another derived base.
        return "\(kindID)-scope-\(scopeLabel.utf8.count):\(scopeLabel)"
    }

    init(
        kind: UsageWindowKind,
        percentUsed: Double,
        resetsAt: Date?,
        windowLength: TimeInterval?,
        scopeLabel: String?,
        severity: UsageSeverity
    ) {
        self.kind = kind
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.windowLength = windowLength
        self.scopeLabel = scopeLabel
        self.severity = severity
        identityOrdinal = 0
    }

    private init(copying window: UsageWindow, identityOrdinal: Int) {
        kind = window.kind
        percentUsed = window.percentUsed
        resetsAt = window.resetsAt
        windowLength = window.windowLength
        scopeLabel = window.scopeLabel
        severity = window.severity
        self.identityOrdinal = identityOrdinal
    }

    fileprivate func assigningIdentityOrdinal(_ ordinal: Int) -> UsageWindow {
        UsageWindow(copying: self, identityOrdinal: ordinal)
    }

    /// Stands in for a scope name the API didn't provide, on a window that IS
    /// scoped (not account-wide).
    ///
    /// `scopeLabel == nil` already means "account-wide" — see
    /// `UsageSnapshot.window(_:)`, which prefers it. If a window we know is
    /// model-scoped (Claude sent a `scope` object; Codex put it in
    /// `additional_rate_limits`) fell back to `nil` just because the name
    /// field was missing, it would either become the account-wide headline
    /// itself or collide with and hide the real one. Dropping the window
    /// instead would throw away a percentage we DO trust — the value that
    /// failed to decode is only the label, not `percentUsed` — so this
    /// placeholder is preferred over `nil` and over discarding the window.
    static let unspecifiedScopeLabel = "Unknown"

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
    /// One-shot quota resets are an account capability, not a time window.
    /// Keeping the count alongside (rather than inside) `windows` prevents a
    /// missing field from masquerading as another healthy 0%-used gauge.
    let limitResetCredits: Int?
    let capturedAt: Date

    init(
        provider: UsageProviderKind,
        account: String?,
        plan: String?,
        billing: UsageBilling,
        windows: [UsageWindow],
        limitResetCredits: Int? = nil,
        capturedAt: Date
    ) {
        self.provider = provider
        self.account = account
        self.plan = plan
        self.billing = billing
        self.limitResetCredits = limitResetCredits
        self.capturedAt = capturedAt

        // The APIs already give us a meaningful order. Reusing it is the only
        // derived way to distinguish genuinely duplicate kind/scope pairs
        // without making volatile percentages or reset metadata into identity.
        var occurrences: [String: Int] = [:]
        self.windows = windows.map { window in
            let ordinal = occurrences[window.identityBase, default: 0]
            occurrences[window.identityBase] = ordinal + 1
            return window.assigningIdentityOrdinal(ordinal)
        }
    }

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
