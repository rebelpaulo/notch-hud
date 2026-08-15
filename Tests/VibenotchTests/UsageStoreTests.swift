import Foundation
import Testing
@testable import Vibenotch

@MainActor
@Test func theLocalScanRepeatsInsteadOfFreezingAfterTheFirstOne() async {
    // It used to refuse to run again once a series existed, so token counts
    // froze at whatever the first scan saw until the app restarted.
    let store = UsageStore(fetchers: [], scanner: LocalUsageScanner(
        claudeHomeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true),
        codexHomeURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-store-tests-\(UUID().uuidString)", isDirectory: true)
    ))

    let start = Date()
    store.scanLocalIfNeeded(now: start)
    while store.lastLocalScan == nil { await Task.yield() }
    let first = store.lastLocalScan

    // Too soon: nothing should move.
    store.scanLocalIfNeeded(now: start.addingTimeInterval(60))
    #expect(store.lastLocalScan == first)

    // Past the window, it goes again.
    let later = start.addingTimeInterval(UsageStore.localScanMaxAge + 1)
    store.scanLocalIfNeeded(now: later)
    while store.lastLocalScan == first { await Task.yield() }
    #expect(store.lastLocalScan == later)
}
