import Foundation
import Testing
@testable import NotchHUD

@Test func envelopeDecodesRichOptionalFields() throws {
    let data = Data(
        """
        {
          "schema": 1,
          "id": "claude-rich",
          "agent": "claude-code",
          "status": "working",
          "task": "Redesign the console",
          "prompt": "Implement the compact and expanded console UI.",
          "toolLine": "Edit SessionRowView.swift",
          "model": "fable-5",
          "updated": "2026-07-21T20:00:30Z",
          "started": "2026-07-21T20:00:00Z",
          "seq": 4
        }
        """.utf8
    )

    let envelope = try JSONDecoder().decode(SessionEnvelope.self, from: data)

    #expect(envelope.task == "Redesign the console")
    #expect(envelope.prompt == "Implement the compact and expanded console UI.")
    #expect(envelope.toolLine == "Edit SessionRowView.swift")
    #expect(envelope.model == "fable-5")
}

@Test func envelopeDecodesWithoutRichOptionalFields() throws {
    let data = Data(
        """
        {
          "schema": 1,
          "id": "legacy-session",
          "agent": "claude-code",
          "status": "done",
          "updated": "2026-07-21T20:00:30Z",
          "seq": 5
        }
        """.utf8
    )

    let envelope = try JSONDecoder().decode(SessionEnvelope.self, from: data)

    #expect(envelope.task == nil)
    #expect(envelope.prompt == nil)
    #expect(envelope.toolLine == nil)
    #expect(envelope.model == nil)
}

@Test func envelopeSourceMapsToSession() throws {
    let data = Data(
        """
        {
          "schema": 1,
          "id": "claude-desktop-session",
          "agent": "claude-code",
          "status": "working",
          "updated": "2026-08-04T12:00:00Z",
          "seq": 1,
          "source": "claude-desktop"
        }
        """.utf8
    )

    let envelope = try JSONDecoder().decode(SessionEnvelope.self, from: data)
    let session = try #require(Session(envelope: envelope))

    #expect(envelope.source == "claude-desktop")
    #expect(session.source == envelope.source)
}
