import Foundation
import SwiftUI

struct NotchPeekView: View {
    let store: SessionStore
    let pendingStore: PendingStore
    var onSizeChange: @MainActor (CGSize) -> Void = { _ in }

    var body: some View {
        Group {
            if pendingStore.hasPending {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    peekContent(pulseOpacity(at: context.date))
                }
            } else {
                peekContent(1)
            }
        }
        .fixedSize()
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { onSizeChange(proxy.size) }
                    .onChange(of: proxy.size) { _, size in onSizeChange(size) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private func peekContent(_ pulseOpacity: Double) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(store.sessions.prefix(3))) { session in
                    AgentSprite(
                        status: session.displayStatus,
                        size: 12,
                        tint: SessionChipStyle.spriteTint(session.agent)
                    )
                }
            }

            if let compactStatus {
                Text(compactStatus.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(compactStatus.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, pendingStore.hasPending ? 6 : 0)
        .padding(.vertical, pendingStore.hasPending ? 3 : 0)
        .background {
            if pendingStore.hasPending {
                Capsule()
                    .fill(DisplayStatus.needsMe.color.opacity(0.15))
                    .opacity(pulseOpacity)
            }
        }
    }

    private var compactStatus: (label: String, color: Color)? {
        if pendingStore.hasPending {
            return ("Approve?", DisplayStatus.needsMe.color)
        }
        let counts = store.counts
        if counts.needsMe > 0 {
            return ("Needs you", DisplayStatus.needsMe.color)
        }
        if counts.working > 0 {
            return ("Working…", .white)
        }
        if store.total > 0, counts.done == store.total {
            return ("Done", DisplayStatus.done.color)
        }
        return nil
    }

    private var accessibilitySummary: String {
        if pendingStore.hasPending {
            return "Approval needed for \(pendingStore.approvals.count) session"
        }
        let counts = store.counts
        return "\(store.total) active sessions, \(counts.working) working, \(counts.needsMe) need attention, \(counts.done) done"
    }

    private func pulseOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        return 0.925 + (0.075 * cos(phase * 2 * .pi))
    }
}

extension Color {
    static let notchBackground = Color(red: 0.078, green: 0.078, blue: 0.086)
}
