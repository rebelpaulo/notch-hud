import Foundation
import Testing
@testable import Vibenotch

@Test func sessionMapsRichFieldsAndStartedAt() throws {
    // A status-only emitter update merges over the old envelope, so these rich values
    // remain present even when the new status is done.
    let envelope = SessionEnvelope(
        schema: 1,
        id: "claude-mapped",
        agent: "claude-code",
        project: "vibenotch",
        status: .done,
        task: "Build the console",
        prompt: "Implement M3 exactly.",
        toolLine: "Edit SessionRowView.swift",
        model: "opus-4.8",
        updated: "2026-07-21T20:07:00Z",
        started: "2026-07-21T20:00:00Z",
        seq: 8
    )

    let session = Session(
        envelope: envelope,
        updatedAt: Date(timeIntervalSince1970: 1_753_128_420)
    )

    #expect(session.task == envelope.task)
    #expect(session.prompt == envelope.prompt)
    #expect(session.toolLine == envelope.toolLine)
    #expect(session.model == envelope.model)
    #expect(session.startedAt != nil)
}

@Test func elapsedFormatsCompactDurations() throws {
    let envelope = SessionEnvelope(
        schema: 1,
        id: "elapsed",
        agent: "codex",
        status: .working,
        updated: "2026-07-21T20:00:00Z",
        started: "2026-07-21T20:00:00Z",
        seq: 1
    )
    let session = Session(
        envelope: envelope,
        updatedAt: Date(timeIntervalSince1970: 1_753_128_000)
    )
    let startedAt = try #require(session.startedAt)

    #expect(session.elapsed(at: startedAt.addingTimeInterval(30)) == "<1m")
    #expect(session.elapsed(at: startedAt.addingTimeInterval(420)) == "7m")
    #expect(session.elapsed(at: startedAt.addingTimeInterval(3_900)) == "1h")
    #expect(session.elapsed(at: startedAt.addingTimeInterval(90_000)) == "1d")
}
