import Foundation
import Testing
@testable import NotchHUD

@MainActor
@Test func codexDesktopFreshRolloutWritesWorkingSpoolEntry() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let rolloutURL = try fixture.writeRollout(originator: "Codex Desktop")
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: rolloutURL)

    fixture.poller.poll(now: fixture.now)

    print("Generated Codex Desktop spool JSON: " + String(
        decoding: try Data(contentsOf: fixture.spoolFileURL),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines))
    let envelope = try fixture.envelope()
    #expect(envelope.id == "codex-app-123e4567")
    #expect(envelope.agent == "codex")
    #expect(envelope.project == "notch-hud")
    #expect(envelope.cwd == "/tmp/projects/notch-hud")
    #expect(envelope.status == .working)
    #expect(envelope.source == "codex-desktop")
    #expect(envelope.seq == 1)
}

@MainActor
@Test func codexExecRolloutIsIgnored() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    _ = try fixture.writeRollout(originator: "codex_exec")

    fixture.poller.poll(now: fixture.now)

    #expect(!fixture.fileManager.fileExists(atPath: fixture.spoolFileURL.path))
}

@MainActor
@Test func staleCodexDesktopRolloutWritesDoneSpoolEntry() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let rolloutURL = try fixture.writeRollout(originator: "Codex Desktop")
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: rolloutURL)

    fixture.poller.poll(now: fixture.now)

    #expect(try fixture.envelope().status == .done)
}

@MainActor
@Test func veryOldCodexDesktopRolloutRemovesOnlyItsSpoolEntry() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let rolloutURL = try fixture.writeRollout(originator: "Codex Desktop")
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-901), for: rolloutURL)
    try fixture.fileManager.createDirectory(
        at: fixture.spoolURL,
        withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: fixture.spoolFileURL)
    let shimURL = fixture.spoolURL.appendingPathComponent("codex-terminal.json")
    try Data("{}".utf8).write(to: shimURL)

    fixture.poller.poll(now: fixture.now)

    #expect(!fixture.fileManager.fileExists(atPath: fixture.spoolFileURL.path))
    #expect(fixture.fileManager.fileExists(atPath: shimURL.path))
}

@MainActor
@Test func codexDesktopSessionCanFocus() throws {
    let session = Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: "codex-app-123e4567",
            agent: "codex",
            status: .working,
            updated: "2026-08-04T12:00:00Z",
            seq: 1,
            source: "codex-desktop"
        ),
        updatedAt: Date(timeIntervalSince1970: 1_775_300_400)
    )

    #expect(session.canFocus)
    #expect(SessionChipStyle.sourceLabel("codex-desktop") == "Desktop")
}

@MainActor
private final class RolloutFixture {
    let fileManager = FileManager.default
    let rootURL: URL
    let sessionsURL: URL
    let spoolURL: URL
    let now = Date(timeIntervalSince1970: 1_775_300_400)
    let poller: CodexRolloutPoller

    var spoolFileURL: URL {
        spoolURL.appendingPathComponent("codex-app-123e4567.json")
    }

    init() throws {
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NotchHUD-CodexRolloutPoller-\(UUID().uuidString)", isDirectory: true)
        sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        spoolURL = rootURL.appendingPathComponent("spool", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        poller = CodexRolloutPoller(
            sessionsRootURL: sessionsURL,
            spoolURL: spoolURL,
            calendar: calendar
        )
    }

    func writeRollout(originator: String) throws -> URL {
        let directoryURL = sessionsURL
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("04", isDirectory: true)
            .appendingPathComponent("04", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(
            "rollout-2026-04-04T12-00-00-123e4567-e89b-12d3-a456-426614174000.jsonl"
        )
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": "123e4567-e89b-12d3-a456-426614174000",
                "cwd": "/tmp/projects/notch-hud",
                "originator": originator,
                "cli_version": "1.2.3"
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: metadata)
        data.append(contentsOf: Data("\n{\"ignored\":true}\n".utf8))
        try data.write(to: fileURL)
        return fileURL
    }

    func setModificationDate(_ date: Date, for fileURL: URL) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    func envelope() throws -> SessionEnvelope {
        try JSONDecoder().decode(SessionEnvelope.self, from: Data(contentsOf: spoolFileURL))
    }

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}
