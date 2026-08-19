import AppKit
import SwiftUI

struct NotchPanelView: View {
    let store: SessionStore
    let pendingStore: PendingStore
    let focusDispatcher: FocusDispatcher
    let updateStore: UpdateStore
    let updateLauncher: TerminalUpdateLauncher
    let decisionWriter: ApprovalDecisionWriter
    @Bindable var keepAwakeEngine: KeepAwakeEngine
    let usageStore: UsageStore
    let closedLidModeAvailable: Bool
    let onOpenSettings: @MainActor () -> Void
    let onApprovalDismiss: @MainActor (String) -> Void
    let onSessionDismiss: @MainActor (String) -> Void
    let onSizeChange: @MainActor (CGSize) -> Void

    @State private var feedback: [String: SessionRowFeedback] = [:]
    @State private var updateFeedback: UpdateNoticeFeedback?
    @State private var updateDidStart = false
    @State private var sessionListHeight: CGFloat?
    /// Which half of the panel you are looking at. One or the other, never
    /// both: the panel is already the height of a notch drawer, and stacking
    /// quotas under a session list would push the sessions off the bottom —
    /// the thing you open this for most often.
    @State private var tab: PanelTab = .sessions

    private enum PanelTab {
        case sessions
        case limits
    }

    /// The quota tab is taller on purpose: two provider cards, each with a
    /// gauge pair and a month of daily bars, do not fit in the height a
    /// session list needs. Growing only on that tab keeps the common case —
    /// glancing at what is running — the same size it has always been.
    private var maximumPanelHeight: CGFloat {
        tab == .limits ? 820 : 520
    }

    private var maximumSessionListHeight: CGFloat {
        pendingStore.hasPending ? 205 : 468
    }

    /// Enough for both cards and both charts without an inner scrollbar in
    /// the ordinary case. It still scrolls when a provider reports extra
    /// model-scoped windows, which is the one thing that varies.
    private var maximumUsageHeight: CGFloat {
        pendingStore.hasPending ? 505 : 768
    }

    private let panelShape = UnevenRoundedRectangle(
        cornerRadii: RectangleCornerRadii(
            topLeading: 0,
            bottomLeading: 22,
            bottomTrailing: 22,
            topTrailing: 0
        ),
        style: .continuous
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let approval = pendingStore.current {
                ApprovalCardView(
                    approval: approval,
                    decisionWriter: decisionWriter,
                    onDismiss: onApprovalDismiss
                )
            }

            if tab == .limits {
                usageTab
            } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if store.sessions.isEmpty && updateStore.availableUpdate == nil {
                    emptyState
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) {
                            if let update = updateStore.availableUpdate {
                                UpdateNoticeView(
                                    update: update,
                                    currentVersion: updateStore.currentVersion,
                                    feedback: updateFeedback,
                                    didStart: updateDidStart,
                                    onSelect: { launchUpdate(update) },
                                    onGrantAccess: openAutomationSettings
                                )
                            }

                            ForEach(store.sessions) { session in
                                SessionRowView(
                                    session: session,
                                    now: context.date,
                                    feedback: feedback[session.id],
                                    onSelect: focus,
                                    onGrantAccess: openAutomationSettings
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { proxy in
                                Color.clear
                                    .onAppear {
                                        sessionListHeight = proxy.size.height
                                    }
                                    .onChange(of: proxy.size.height) { _, height in
                                        sessionListHeight = height
                                    }
                            }
                        }
                    }
                    .frame(
                        height: min(
                            sessionListHeight ?? maximumSessionListHeight,
                            maximumSessionListHeight
                        )
                    )
                }
            }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(
            minWidth: 680,
            maxWidth: 680,
            maxHeight: maximumPanelHeight,
            alignment: .top
        )
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.notchBackground.opacity(0.97))
        .clipShape(panelShape)
        .overlay {
            panelShape
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        onSizeChange(proxy.size)
                    }
                    .onChange(of: proxy.size) { _, size in
                        onSizeChange(size)
                    }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 4) {
                summaryPart(store.counts.working, t("working"), color: DisplayStatus.working.color)
                summarySeparator
                summaryPart(store.counts.needsMe, t("need you"), color: DisplayStatus.needsMe.color)
                summarySeparator
                summaryPart(store.counts.done, t("done"), color: DisplayStatus.done.color)
            }

            Spacer()

            allNighterControl

            tabToggle

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("Open settings"))
            .accessibilityLabel(t("Settings"))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }

    /// Swaps the panel between the session list and the quota gauges. One
    /// button rather than a segmented control: there are exactly two places to
    /// be, and the icon can then show where you would GO, which is the thing
    /// worth a glance in a strip this narrow.
    private var tabToggle: some View {
        Button {
            tab = tab == .sessions ? .limits : .sessions
            if tab == .limits {
                usageStore.refreshIfStale()
                usageStore.scanLocalIfNeeded()
            }
        } label: {
            Image(systemName: tab == .sessions ? "gauge.with.needle" : "list.bullet")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22, height: 20)
                .background(.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab == .sessions ? t("Show the quota limits") : t("Show the sessions"))
        .accessibilityLabel(tab == .sessions ? t("Show the quota limits") : t("Show the sessions"))
    }

    /// What one provider's slot in the tab draws, once it has anything to
    /// say at all.
    private enum UsageTabEntry {
        case loaded(UsageSnapshot)
        case unavailable(UsageUnavailable)
    }

    /// Only the providers with something to show. A card reading
    /// "unavailable" for a tool you do not use is noise about someone else's
    /// product; absence says the same thing without occupying the drawer.
    ///
    /// "Not signed in" is the one reason that disappears entirely — "a regra
    /// se não tem login não apresenta" — because there is nothing here that
    /// is this app's problem to report: the fix is the user signing in, and
    /// showing a row for every service they have never used would make the
    /// drawer about Claude/Codex/Grok's product line instead of about their
    /// sessions. Network hiccups, an expired login, and a reshaped response
    /// ARE this app's business (or at least worth a glance), so those keep a
    /// row via `UsageCardView`'s `unavailable` init. One rule, applied the
    /// same way to all three providers rather than special-cased per one.
    ///
    /// A provider that answered once and then failed keeps its LOADED card,
    /// because UsageStore holds the last good snapshot — a dropped request
    /// is not evidence you logged out. Only a provider that has never once
    /// loaded successfully can show the unavailable row instead.
    private var usageTab: some View {
        let shown = UsageProviderKind.allCases.compactMap { provider -> (UsageProviderKind, UsageTabEntry)? in
            switch usageStore.entries[provider] {
            case .loaded(let snapshot):
                return (provider, .loaded(snapshot))
            case .failed(let reason) where reason != .notLoggedIn:
                return (provider, .unavailable(reason))
            default:
                // .none (never fetched), .loading, and .failed(.notLoggedIn)
                // all render nothing — see the doc comment above.
                return nil
            }
        }

        return ScrollView(.vertical) {
            VStack(spacing: 10) {
                if shown.isEmpty {
                    // Not a per-card badge: one quiet line, and only when
                    // there is genuinely nothing to draw.
                    Text(usageStore.isLoading ? t("Checking…") : t("Sign in with claude, codex, or grok to see quotas"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }

                ForEach(shown, id: \.0.rawValue) { provider, entry in
                    switch entry {
                    case .loaded(let snapshot):
                        VStack(alignment: .leading, spacing: 10) {
                            UsageCardView(
                                snapshot: snapshot,
                                paceByWindowID: usageStore.pace(for: snapshot)
                            )

                            UsageHistoryChart(
                                provider: provider,
                                points: usageStore.localSeries?.points ?? [],
                                today: usageStore.tokens(for: provider, today: true),
                                trailing: usageStore.tokens(for: provider, today: false),
                                isCounting: usageStore.isScanningLocal
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                        }
                        .background(Color.notchBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    case .unavailable(let reason):
                        UsageCardView(provider: provider, unavailable: reason)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: maximumUsageHeight)
    }

    private var allNighterControl: some View {
        HStack(spacing: 2) {
            Button {
                if keepAwakeEngine.isActive {
                    keepAwakeEngine.setMode(.off)
                } else {
                    keepAwakeEngine.setMode(safeDefaultMode)
                }
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        keepAwakeEngine.isActive
                            ? Color(nsColor: .systemRed)
                            : .white.opacity(0.38)
                    )
                    .frame(width: 22, height: 20)
                    .background(.white.opacity(keepAwakeEngine.isActive ? 0.09 : 0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(keepAwakeEngine.isActive ? t("Turn off Gotta go!") : t("Turn on Gotta go!"))
            .accessibilityLabel(keepAwakeEngine.isActive ? t("Turn off Gotta go!") : t("Turn on Gotta go!"))

            // Only when it is worth knowing. A thermometer that is always there
            // is furniture; one that only appears when the Mac is struggling is
            // information — and with the lid shut this is the one thing Gotta
            // go! can make worse.
            if let heat = heatWarning {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(heat.color)
                    .frame(width: 18, height: 20)
                    .help(heat.label)
                    .accessibilityLabel(heat.label)
            }

            Menu {
                modeButton(t("While agents are working"), mode: .whileAgentsWork)
                modeButton(t("While the apps are open"), mode: .whileAppsRunning)
                Divider()
                timerButton("30 min", seconds: 30 * 60)
                timerButton("1h", seconds: 60 * 60)
                timerButton("2h", seconds: 2 * 60 * 60)
                modeButton(t("Indefinitely"), mode: .manual)
                Divider()
                Toggle(t("Let the display sleep"), isOn: keepAwakeEngine.configBinding(\.allowDisplaySleep))
                Toggle(
                    t("Stay awake with the lid closed"),
                    isOn: keepAwakeEngine.configBinding(\.closedLidMode)
                )
                .disabled(!closedLidModeAvailable)
                if !closedLidModeAvailable {
                    Text(t("In the vibenotch repo, run install-gotta-go.sh with sudo"))
                }
                Toggle(t("Turn off on unlock"), isOn: keepAwakeEngine.configBinding(\.autoOffOnUnlock))
                if keepAwakeEngine.isActive {
                    Divider()
                    Text(activeFooter)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 14, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(t("Gotta go! options"))
            .accessibilityLabel(t("Gotta go! options"))
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private var safeDefaultMode: KeepAwakeMode {
        switch keepAwakeEngine.config.defaultMode {
        case .off, .timer:
            return .whileAgentsWork
        case let mode:
            return mode
        }
    }

    private func modeButton(_ title: String, mode: KeepAwakeMode) -> some View {
        Button {
            keepAwakeEngine.config.defaultMode = mode
            keepAwakeEngine.setMode(mode)
        } label: {
            if keepAwakeEngine.mode == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func timerButton(_ title: String, seconds: TimeInterval) -> some View {
        Button(title) {
            keepAwakeEngine.setMode(.timer(until: Date().addingTimeInterval(seconds)))
        }
    }

    /// Nothing below `serious`: `nominal` and `fair` are a Mac doing its job.
    private var heatWarning: (color: Color, label: String)? {
        switch keepAwakeEngine.thermalState {
        case .serious:
            (Color(nsColor: .systemOrange), t("The Mac is running hot"))
        case .critical:
            // Promising a shutdown that already happened — or that was never
            // running — is worse than saying nothing about it.
            (
                Color(nsColor: .systemRed),
                keepAwakeEngine.isActive
                    ? t("The Mac is overheating — Gotta go! is turning off")
                    : t("The Mac is overheating")
            )
        default:
            nil
        }
    }

    private var activeFooter: String {
        let elapsed = max(0, Date().timeIntervalSince(keepAwakeEngine.activeSince ?? Date()))
        var footer = t("on for %@ · %@ mode", compactDuration(elapsed), modeName(keepAwakeEngine.mode))
        if let remaining = keepAwakeEngine.remainingTime(at: Date()) {
            footer += t(" · %@ left", compactDuration(remaining))
        }
        return footer
    }

    private func modeName(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: t("off")
        case .manual: t("indefinite")
        case .timer: t("timer")
        case .whileAgentsWork: t("agents")
        case .whileAppsRunning: t("apps")
        }
    }

    private func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes >= 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }

    private func summaryPart(_ count: Int, _ label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .foregroundStyle(.white.opacity(0.58))
        }
    }

    private var summarySeparator: some View {
        Text("·")
            .foregroundStyle(.white.opacity(0.28))
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            AgentSprite(status: .idle, size: 18)
            Text(t("No active sessions"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
    }

    private func focus(_ session: Session) {
        guard session.canFocus else { return }
        feedback[session.id] = nil

        Task {
            switch await focusDispatcher.focus(session) {
            case .success:
                // Clicking a finished session is an acknowledgment: jump AND
                // clear the card (otherwise done cards linger until the 15min
                // sweep). Dismiss only after a successful raise so focus
                // failures keep the row + feedback visible.
                if session.displayStatus == .done {
                    onSessionDismiss(session.id)
                }
            case .failure(.permissionDenied):
                show(.permissionDenied, for: session.id, duration: .seconds(10))
            case .failure(.notFound), .failure(.scriptFailed):
                show(.notFound, for: session.id, duration: .seconds(2))
            }
        }
    }

    private func launchUpdate(_ update: AvailableUpdate) {
        updateFeedback = nil
        updateDidStart = false

        switch updateLauncher.launch(update) {
        case .success:
            updateDidStart = true
        case .failure(.permissionDenied):
            updateFeedback = .permissionDenied
        case .failure(.notFound):
            updateFeedback = .helperMissing
        case .failure(.scriptFailed):
            updateFeedback = .launchFailed
        }
    }

    private func show(_ value: SessionRowFeedback, for sessionID: String, duration: Duration) {
        feedback[sessionID] = value

        Task {
            try? await Task.sleep(for: duration)
            if feedback[sessionID] == value {
                feedback[sessionID] = nil
            }
        }
    }

    private func openAutomationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
