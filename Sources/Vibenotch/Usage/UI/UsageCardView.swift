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

    init(snapshot: UsageSnapshot, paceByWindowID: [String: UsagePace] = [:], now: Date = .now) {
        provider = snapshot.provider
        self.snapshot = snapshot
        unavailable = nil
        self.paceByWindowID = paceByWindowID
        self.now = now
    }

    init(provider: UsageProviderKind, unavailable: UsageUnavailable, now: Date = .now) {
        self.provider = provider
        snapshot = nil
        self.unavailable = unavailable
        paceByWindowID = [:]
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let snapshot {
                if let session = snapshot.window(.session) {
                    section(title: t("Session"), window: session)
                }
                if let weekly = snapshot.window(.weekly) {
                    section(title: t("Weekly"), window: weekly)
                }

                let scoped = snapshot.windows.filter { $0.scopeLabel != nil }
                if !scoped.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(scoped) { window in
                            compactRow(window)
                        }
                    }
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
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
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

        return HStack(spacing: 8) {
            Text(window.scopeLabel ?? t("Model"))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)

            UsageGauge(
                percentUsed: window.percentUsed,
                pace: pace,
                tint: provider.tint,
                accessibilityLabel: window.scopeLabel ?? t("Model"),
                accessibilityValue: gaugeAccessibilityValue(window, pace)
            )

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
