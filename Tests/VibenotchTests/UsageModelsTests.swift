import Foundation
import Testing
@testable import Vibenotch

@Test func usageSnapshotAssignsAUniqueIDToEveryWindow() {
    let reset = Date(timeIntervalSince1970: 1_000_000.125)
    let snapshot = usageSnapshot(windows: [
        usageWindow(resetsAt: reset),
        usageWindow(resetsAt: reset.addingTimeInterval(0.25)),
        usageWindow(resetsAt: nil),
        usageWindow(resetsAt: nil),
    ])

    #expect(Set(snapshot.windows.map(\.id)).count == snapshot.windows.count)
}

@Test func usageWindowIDDoesNotChangeWithResetMetadata() {
    let first = usageSnapshot(windows: [
        usageWindow(resetsAt: Date(timeIntervalSince1970: 1_000_000.125)),
    ])
    let refreshed = usageSnapshot(windows: [
        usageWindow(resetsAt: nil),
    ])

    #expect(first.windows[0].id == refreshed.windows[0].id)
}

@Test func duplicateUsageWindowIDsStayPositionalAcrossRefreshes() {
    let first = usageSnapshot(windows: [
        usageWindow(percentUsed: 20, resetsAt: Date(timeIntervalSince1970: 1_000_000)),
        usageWindow(percentUsed: 40, resetsAt: Date(timeIntervalSince1970: 2_000_000)),
    ])
    let refreshed = usageSnapshot(windows: [
        usageWindow(percentUsed: 21, resetsAt: nil),
        usageWindow(percentUsed: 42, resetsAt: Date(timeIntervalSince1970: 3_000_000)),
    ])

    #expect(first.windows.map(\.id) == refreshed.windows.map(\.id))
}

private func usageWindow(percentUsed: Double = 10, resetsAt: Date?) -> UsageWindow {
    UsageWindow(
        kind: .weekly,
        percentUsed: percentUsed,
        resetsAt: resetsAt,
        windowLength: nil,
        scopeLabel: nil,
        severity: .normal
    )
}

private func usageSnapshot(windows: [UsageWindow]) -> UsageSnapshot {
    UsageSnapshot(
        provider: .claude,
        account: nil,
        plan: nil,
        billing: .plan(nil),
        windows: windows,
        capturedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}
