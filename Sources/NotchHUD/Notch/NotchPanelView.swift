import AppKit
import SwiftUI

struct NotchPanelView: View {
    let store: SessionStore
    let pendingStore: PendingStore
    let focusDispatcher: FocusDispatcher
    let decisionWriter: ApprovalDecisionWriter
    let onApprovalDismiss: @MainActor (String) -> Void
    let onSessionDismiss: @MainActor (String) -> Void
    let onSizeChange: @MainActor (CGSize) -> Void

    @State private var feedback: [String: SessionRowFeedback] = [:]
    @State private var sessionListHeight: CGFloat?

    private let maximumPanelHeight: CGFloat = 520
    private var maximumSessionListHeight: CGFloat {
        pendingStore.hasPending ? 205 : 468
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

            TimelineView(.periodic(from: .now, by: 30)) { context in
                if store.sessions.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) {
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
                summaryPart(store.counts.working, "working", color: DisplayStatus.working.color)
                summarySeparator
                summaryPart(store.counts.needsMe, "needs you", color: DisplayStatus.needsMe.color)
                summarySeparator
                summaryPart(store.counts.done, "done", color: DisplayStatus.done.color)
            }

            Spacer()

            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityLabel("Settings")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
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
            Text("No active sessions")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
    }

    private func focus(_ session: Session) {
        guard session.canFocus else { return }
        feedback[session.id] = nil

        // Clicking a finished session is an acknowledgment: jump AND clear
        // the card (otherwise done cards linger until the 15min sweep).
        if session.displayStatus == .done {
            onSessionDismiss(session.id)
        }

        Task {
            switch await focusDispatcher.focus(session) {
            case .success:
                break
            case .failure(.permissionDenied):
                show(.permissionDenied, for: session.id, duration: .seconds(10))
            case .failure(.notFound), .failure(.scriptFailed):
                show(.notFound, for: session.id, duration: .seconds(2))
            }
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
