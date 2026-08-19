import SwiftUI

/// One provider's limits: a header, a Session gauge, a Weekly gauge, and any
/// model-scoped windows below. Pure presentation — everything it draws is
/// handed in already computed; it fetches nothing and owns no timer.
struct UsageCardView: View {
    let provider: UsageProviderKind
    private let snapshot: UsageSnapshot?
    private let unavailable: UsageUnavailable?
    /// Pace is per window, keyed by `UsageWindow.id` — the model computing it
    /// (a separate ticket) has no reason to know this view exists, so the
    /// keying happens here rather than on the model.
    private let paceByWindowID: [String: UsagePace]
    private let now: Date
    /// Whether this card shows everything or just its header + first window.
    /// Owned by the parent, not local `@State`: exactly one card across the
    /// whole tab may be expanded at a time, which only the parent can enforce.
    private let isExpanded: Bool
    private let onToggleExpanded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringHeader = false

    init(
        snapshot: UsageSnapshot,
        paceByWindowID: [String: UsagePace] = [:],
        now: Date = .now,
        isExpanded: Bool = true,
        onToggleExpanded: @escaping () -> Void = {}
    ) {
        provider = snapshot.provider
        self.snapshot = snapshot
        unavailable = nil
        self.paceByWindowID = paceByWindowID
        self.now = now
        self.isExpanded = isExpanded
        self.onToggleExpanded = onToggleExpanded
    }

    /// Unavailable cards have no windows to hide, so they are never
    /// collapsible — `isExpanded` always reads true and the header ignores taps.
    init(provider: UsageProviderKind, unavailable: UsageUnavailable, now: Date = .now) {
        self.provider = provider
        snapshot = nil
        self.unavailable = unavailable
        paceByWindowID = [:]
        self.now = now
        isExpanded = true
        onToggleExpanded = {}
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let snapshot {
                if isExpanded {
                    if let session = snapshot.window(.session) {
                        section(title: windowTitle(session), window: session)
                    }
                    if let weekly = snapshot.window(.weekly) {
                        section(title: windowTitle(weekly), window: weekly)
                    }

                    let scoped = snapshot.windows.filter { $0.scopeLabel != nil }
                    if !scoped.isEmpty {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            ForEach(scoped) { window in
                                compactRow(window)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let credits = UsageFormatting.limitResetCredits(snapshot.limitResetCredits) {
                        Text(credits)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                } else if let firstWindow = snapshot.windows.first {
                    // Whichever window the provider reported first — never a
                    // hardcoded "Session" — because that is the one fact still
                    // true the day a provider's shape changes, as Grok (no
                    // session window at all) already proves.
                    section(title: windowTitle(firstWindow), window: firstWindow)
                }
            } else {
                unavailableRow
            }
        }
        .padding(12)
        // Fills the notch drawer rather than sitting in a 300pt column: the
        // panel is 680pt wide, and a gauge that spans it resolves to about
        // twice the pixels per percent, which is the whole readability of a
        // 6pt bar you glance at.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.notchBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        }
        // Collapsed, the WHOLE card opens it — not just the title row. What is
        // on screen when collapsed is a summary of one thing, so every part of
        // it means the same "show me the rest"; making the user find the 20pt
        // header is a hit-target puzzle with no upside.
        //
        // Expanded, only the header collapses it again. A card full of gauges
        // is content to read, and a stray click while reading should not make
        // it vanish.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard !isExpanded else { return }
            onToggleExpanded()
        }
    }

    // MARK: Header

    /// The whole row is the click target, not just the chevron — a real
    /// `Button` so VoiceOver announces it as one, rather than a tap gesture
    /// bolted onto a stack. Disabled (and un-hoverable) when there is no
    /// snapshot: an unavailable card has nothing behind it to expand.
    private var header: some View {
        Button(action: onToggleExpanded) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        if snapshot != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.4))
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
                        }
                    }
                    if let snapshot {
                        Text(UsageFormatting.relativeUpdated(snapshot.capturedAt, now: now))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                Spacer()

                if let snapshot {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let account = snapshot.account, !account.isEmpty {
                            Text(account)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                        if let plan = snapshot.plan, !plan.isEmpty {
                            Text(plan)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
            }
            .background(.white.opacity(isHoveringHeader && snapshot != nil ? 0.06 : 0))
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(snapshot == nil)
        .onHover { hovering in
            isHoveringHeader = snapshot != nil && hovering
        }
        .accessibilityLabel(headerAccessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var headerAccessibilityLabel: String {
        guard snapshot != nil else { return provider.displayName }
        return isExpanded
            ? t("%@ usage, expanded", provider.displayName)
            : t("%@ usage, collapsed", provider.displayName)
    }

    /// The label a window's own section carries — its scope name if it has
    /// one, else derived from `kind`. Never a fixed per-provider guess: this
    /// is what lets the collapsed row show whichever window came first
    /// without knowing which provider it belongs to.
    private func windowTitle(_ window: UsageWindow) -> String {
        if let scopeLabel = window.scopeLabel { return scopeLabel }
        return window.kind == .session ? t("Session") : t("Weekly")
    }

    // MARK: Session / Weekly section

    private func section(title: String, window: UsageWindow) -> some View {
        let pace = paceByWindowID[window.id]

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))

            UsageGauge(
                percentUsed: window.percentUsed,
                pace: pace,
                tint: provider.tint,
                accessibilityLabel: title,
                accessibilityValue: gaugeAccessibilityValue(window, pace)
            )

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(UsageFormatting.percentLeft(window.percentLeft))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    if let pace {
                        Text(UsageFormatting.pacePhrase(pace))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(UsageFormatting.countdown(to: window.resetsAt, from: now))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    if let pace {
                        Text(UsageFormatting.projectionPhrase(pace, now: now))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
    }

    // MARK: Model-scoped windows

    private func compactRow(_ window: UsageWindow) -> some View {
        let pace = paceByWindowID[window.id]

        return GridRow(alignment: .center) {
            Text(window.scopeLabel ?? t("Model"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                // Scoped names should size their shared Grid column naturally
                // now that the card is wide. The cap is what keeps an absurdly
                // long server-provided name from consuming the gauge or the
                // fixed percentage column at the far edge.
                .frame(maxWidth: 220, alignment: .leading)

            UsageGauge(
                percentUsed: window.percentUsed,
                pace: pace,
                tint: provider.tint,
                accessibilityLabel: window.scopeLabel ?? t("Model"),
                accessibilityValue: gaugeAccessibilityValue(window, pace)
            )
            .frame(minWidth: 120, maxWidth: .infinity)

            Text(UsageFormatting.percentLeft(window.percentLeft))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func gaugeAccessibilityValue(_ window: UsageWindow, _ pace: UsagePace?) -> String {
        guard let pace else { return UsageFormatting.percentUsed(window.percentUsed) }
        return "\(UsageFormatting.percentUsed(window.percentUsed)), \(UsageFormatting.pacePhrase(pace))"
    }

    // MARK: Unavailable

    private var unavailableRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
            Text(unavailableMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var unavailableMessage: String {
        switch unavailable {
        case .notLoggedIn:
            t("Not logged in")
        case .credentialExpired:
            t("Login expired")
        case .network:
            t("Couldn't reach %@", provider.displayName)
        case .unexpectedResponse:
            t("Couldn't read %@ usage", provider.displayName)
        case nil:
            t("No usage data")
        }
    }
}

// MARK: - Previews

#Preview("Healthy — session + weekly") {
    UsageCardView(
        snapshot: UsageSnapshot(
            provider: .claude,
            account: "paulo@originaly.dev",
            plan: "Max 20x",
            billing: .plan("Max 20x"),
            windows: [
                UsageWindow(
                    kind: .session,
                    percentUsed: 40,
                    resetsAt: Date().addingTimeInterval(2 * 3_600 + 53 * 60),
                    windowLength: 5 * 3_600,
                    scopeLabel: nil,
                    severity: .normal
                ),
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 22,
                    resetsAt: Date().addingTimeInterval(5 * 86_400 + 4 * 3_600),
                    windowLength: 7 * 86_400,
                    scopeLabel: nil,
                    severity: .normal
                )
            ],
            capturedAt: Date().addingTimeInterval(-120)
        ),
        paceByWindowID: [
            "session-account": UsagePace(expectedPercent: 45, deltaPercent: -5, runsOutAt: nil),
            "weekly-account": UsagePace(expectedPercent: 20, deltaPercent: 2, runsOutAt: nil)
        ]
    )
    .padding()
    .background(Color.notchBackground)
}

#Preview("Weekly 84% — ahead of pace") {
    UsageCardView(
        snapshot: UsageSnapshot(
            provider: .codex,
            account: "paulo@originaly.dev",
            plan: "Pro",
            billing: .plan("Pro"),
            windows: [
                UsageWindow(
                    kind: .session,
                    percentUsed: 18,
                    resetsAt: Date().addingTimeInterval(45 * 60),
                    windowLength: 5 * 3_600,
                    scopeLabel: nil,
                    severity: .normal
                ),
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 84,
                    resetsAt: Date().addingTimeInterval(28 * 86_400 + 2 * 3_600),
                    windowLength: 7 * 86_400,
                    scopeLabel: nil,
                    severity: .critical
                )
            ],
            capturedAt: Date().addingTimeInterval(-30 * 60)
        ),
        paceByWindowID: [
            "session-account": UsagePace(expectedPercent: 15, deltaPercent: 3, runsOutAt: nil),
            "weekly-account": UsagePace(
                expectedPercent: 55,
                deltaPercent: 29,
                runsOutAt: Date().addingTimeInterval(5 * 3_600 + 4 * 60)
            )
        ]
    )
    .padding()
    .background(Color.notchBackground)
}

#Preview("Model-scoped window") {
    UsageCardView(
        snapshot: UsageSnapshot(
            provider: .claude,
            account: "paulo@originaly.dev",
            plan: "Max 20x",
            billing: .plan("Max 20x"),
            windows: [
                UsageWindow(
                    kind: .session,
                    percentUsed: 33,
                    resetsAt: Date().addingTimeInterval(3 * 3_600),
                    windowLength: 5 * 3_600,
                    scopeLabel: nil,
                    severity: .normal
                ),
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 61,
                    resetsAt: Date().addingTimeInterval(3 * 86_400),
                    windowLength: 7 * 86_400,
                    scopeLabel: nil,
                    severity: .warning
                ),
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 90,
                    resetsAt: Date().addingTimeInterval(3 * 86_400),
                    windowLength: 7 * 86_400,
                    scopeLabel: "Opus",
                    severity: .critical
                )
            ],
            capturedAt: Date().addingTimeInterval(-5)
        ),
        paceByWindowID: [
            "weekly-account": UsagePace(expectedPercent: 58, deltaPercent: 3, runsOutAt: nil)
        ]
    )
    .padding()
    .background(Color.notchBackground)
}

#Preview("Unavailable") {
    VStack(spacing: 12) {
        UsageCardView(provider: .claude, unavailable: .notLoggedIn)
        UsageCardView(provider: .codex, unavailable: .network("timed out"))
    }
    .padding()
    .background(Color.notchBackground)
}

// Grok, not Claude or Codex: it has no session window at all, so the
// collapsed row below has to lead with Weekly — proof this reads whatever
// window came back first instead of a hardcoded "Session".
#Preview("Collapsed — Grok, weekly leads") {
    UsageCardView(
        snapshot: UsageSnapshot(
            provider: .grok,
            account: "paulo@originaly.dev",
            plan: "SuperGrok",
            billing: .plan("SuperGrok"),
            windows: [
                UsageWindow(
                    kind: .weekly,
                    percentUsed: 47,
                    resetsAt: Date().addingTimeInterval(3 * 86_400 + 6 * 3_600),
                    windowLength: 7 * 86_400,
                    scopeLabel: nil,
                    severity: .normal
                )
            ],
            capturedAt: Date().addingTimeInterval(-90)
        ),
        isExpanded: false
    )
    .padding()
    .background(Color.notchBackground)
}
