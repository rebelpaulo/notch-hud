import Foundation
import Testing
@testable import NotchHUD

@MainActor
@Test func desktopSessionSortsAsFocusableAheadOfOtherTtylessSessions() {
    let store = SessionStore()
    let desktop = makeStoreSession(id: "desktop", source: "claude-desktop", updatedAt: 100)
    let background = makeStoreSession(id: "background", source: "notch-emit", updatedAt: 200)

    store.apply([background, desktop])

    #expect(store.sessions.map(\.id) == ["desktop", "background"])
}

private func makeStoreSession(id: String, source: String, updatedAt: TimeInterval) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: id,
            agent: "claude-code",
            status: .working,
            updated: "2026-08-04T12:00:00Z",
            seq: 1,
            source: source
        ),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
