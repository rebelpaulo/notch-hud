import Foundation
import Testing
@testable import Vibenotch

@MainActor
@Test func desktopSessionSortsAsFocusableAheadOfOtherTtylessSessions() {
    let store = SessionStore()
    let desktop = makeStoreSession(id: "desktop", source: "claude-desktop", updatedAt: 100)
    let background = makeStoreSession(id: "background", source: "vibenotch-emit", updatedAt: 200)

    store.apply([background, desktop])

    #expect(store.sessions.map(\.id) == ["desktop", "background"])
}

@MainActor
@Test func finishedSessionsCollapseToNewestEntryPerProject() {
    let store = SessionStore()

    store.apply([
        makeStoreSession(id: "venue-old", project: "Venue taylor", status: .done, updatedAt: 100),
        makeStoreSession(id: "venue-new", project: "Venue taylor", status: .done, updatedAt: 200),
        makeStoreSession(id: "realtime", project: "realtime-voice-chat-3", status: .done, updatedAt: 150),
    ])

    #expect(Set(store.sessions.map(\.id)) == ["venue-new", "realtime"])
    #expect(store.counts.done == 2)
    #expect(store.sessionsWithoutPendingOverlay.count == 3)
}

@MainActor
@Test func activeProjectHidesItsFinishedHistory() {
    let store = SessionStore()

    store.apply([
        makeStoreSession(id: "finished", project: "Venue taylor", status: .done, updatedAt: 200),
        makeStoreSession(id: "active", project: "Venue taylor", status: .working, updatedAt: 100),
    ])

    #expect(store.sessions.map(\.id) == ["active"])
    #expect(store.counts.working == 1)
    #expect(store.counts.done == 0)
}

@MainActor
@Test func concurrentActiveSessionsForProjectRemainVisible() {
    let store = SessionStore()

    store.apply([
        makeStoreSession(id: "working", project: "Venue taylor", status: .working, updatedAt: 100),
        makeStoreSession(id: "needs-me", project: "Venue taylor", status: .needs_me, updatedAt: 200),
        makeStoreSession(id: "finished", project: "Venue taylor", status: .done, updatedAt: 300),
    ])

    #expect(store.sessions.map(\.id) == ["needs-me", "working"])
}

@MainActor
@Test func pendingApprovalKeepsOlderProjectSessionVisible() {
    let store = SessionStore()
    store.apply([
        makeStoreSession(id: "approval", project: "Venue taylor", status: .done, updatedAt: 100),
        makeStoreSession(id: "finished", project: "Venue taylor", status: .done, updatedAt: 200),
    ])

    store.markPendingApprovals(sessionIDs: ["approval"])

    #expect(store.sessions.map(\.id) == ["approval"])
    #expect(store.sessions.first?.status == .needs_me)
}

private func makeStoreSession(
    id: String,
    project: String? = nil,
    status: SessionStatus = .working,
    source: String = "codex-desktop",
    updatedAt: TimeInterval
) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: id,
            agent: "claude-code",
            project: project ?? id,
            status: status,
            updated: "2026-08-04T12:00:00Z",
            seq: 1,
            source: source
        ),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
