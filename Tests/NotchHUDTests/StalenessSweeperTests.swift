import Foundation
import Testing
@testable import NotchHUD

@MainActor
@Test func sweeperKeepsFinishedDesktopSessionsUntilDrop() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("sweeper-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = SessionStore()
    let sweeper = StalenessSweeper(spoolURL: scratch, store: store)

    store.apply([
        makeSweeperSession(id: "claude-desk", status: .done, source: "claude-desktop", updatedAt: now.addingTimeInterval(-30)),
        makeSweeperSession(id: "codex-desk", status: .done, source: "codex-desktop", updatedAt: now.addingTimeInterval(-30)),
        makeSweeperSession(id: "background", status: .done, source: "notch-emit", updatedAt: now.addingTimeInterval(-30)),
        makeSweeperSession(id: "ancient-desk", status: .done, source: "claude-desktop", updatedAt: now.addingTimeInterval(-16 * 60)),
    ])

    sweeper.sweep(now: now)

    let remaining = Set(store.sessions.map(\.id))
    // finished desktop sessions stay visible; background noise and >15min drop
    #expect(remaining == ["claude-desk", "codex-desk"])
}

private func makeSweeperSession(
    id: String,
    status: SessionStatus,
    source: String,
    updatedAt: Date
) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: id,
            agent: "claude-code",
            status: status,
            updated: "2026-08-04T12:00:00Z",
            seq: 1,
            source: source
        ),
        updatedAt: updatedAt
    )
}
