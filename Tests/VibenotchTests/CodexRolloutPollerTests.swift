import Foundation
import Testing
@testable import Vibenotch

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
    #expect(envelope.project == "vibenotch")
    #expect(envelope.cwd == "/tmp/projects/vibenotch")
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
@Test func staleParentWithTwoFreshSubagentsStaysWorkingWithoutChildEntries() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let parentURL = try fixture.writeRollout(originator: "Codex Desktop")
    let firstSubagentURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID,
        name: "researcher"
    )
    let secondSubagentURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID,
        name: "reviewer"
    )
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: parentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-5), for: firstSubagentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: secondSubagentURL)

    fixture.poller.poll(now: fixture.now)

    let json = String(
        decoding: try Data(contentsOf: fixture.spoolFileURL),
        as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    print("Generated parent envelope with subagents: \(json)")
    let envelope = try fixture.envelope()
    #expect(envelope.status == .working)
    #expect(envelope.toolLine == "2 subagents working")
    let spoolEntries = try fixture.fileManager.contentsOfDirectory(atPath: fixture.spoolURL.path)
    #expect(spoolEntries == ["codex-app-123e4567.json"])
}

@MainActor
@Test func staleSubagentsLetParentFinishAndClearToolLine() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let parentURL = try fixture.writeRollout(originator: "Codex Desktop")
    let firstSubagentURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID,
        name: "researcher"
    )
    let secondSubagentURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID,
        name: "reviewer"
    )
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: parentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-5), for: firstSubagentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: secondSubagentURL)
    fixture.poller.poll(now: fixture.now)

    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: firstSubagentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: secondSubagentURL)
    fixture.poller.poll(now: fixture.now)

    let envelope = try fixture.envelope()
    #expect(envelope.status == .done)
    #expect(envelope.toolLine == nil)
    let rawEnvelope = try JSONSerialization.jsonObject(
        with: Data(contentsOf: fixture.spoolFileURL)
    ) as? [String: Any]
    #expect(rawEnvelope?["toolLine"] == nil)
}

@MainActor
@Test func freshSubagentCreatesMissingParentEntryFromItsCWD() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let missingParentID = "87654321-e89b-12d3-a456-426614174999"
    let subagentURL = try fixture.writeSubagentRollout(
        parentID: missingParentID,
        name: "aquarium"
    )
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-5), for: subagentURL)

    fixture.poller.poll(now: fixture.now)

    let envelope = try fixture.envelope(sessionID: "codex-app-87654321")
    #expect(envelope.id == "codex-app-87654321")
    #expect(envelope.cwd == "/tmp/projects/vibenotch")
    #expect(envelope.project == "vibenotch")
    #expect(envelope.status == .working)
    #expect(envelope.toolLine == "1 subagent working")
}

@MainActor
@Test func unchangedSubagentCountPreservesSeqAndCountChangeBumpsOnce() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let parentURL = try fixture.writeRollout(originator: "Codex Desktop")
    let firstSubagentURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID,
        name: "researcher"
    )
    let secondSubagentURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID,
        name: "reviewer"
    )
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: parentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-5), for: firstSubagentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: secondSubagentURL)

    fixture.poller.poll(now: fixture.now)
    fixture.poller.poll(now: fixture.now)
    var envelope = try fixture.envelope()
    #expect(envelope.seq == 1)
    #expect(envelope.toolLine == "2 subagents working")

    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: secondSubagentURL)
    fixture.poller.poll(now: fixture.now)
    envelope = try fixture.envelope()
    #expect(envelope.seq == 2)
    #expect(envelope.toolLine == "1 subagent working")

    fixture.poller.poll(now: fixture.now)
    #expect(try fixture.envelope().seq == 2)
}

@MainActor
@Test func duplicateSubagentRolloutAcrossDayDirsCountsOnce() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let parentURL = try fixture.writeRollout(originator: "Codex Desktop")
    let sharedID = "aaaabbbb-e89b-12d3-a456-426614174111"
    let today = try fixture.writeSubagentRollout(
        parentID: fixture.parentID, name: "researcher", subagentID: sharedID, day: "04"
    )
    let yesterday = try fixture.writeSubagentRollout(
        parentID: fixture.parentID, name: "researcher", subagentID: sharedID, day: "03"
    )
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: parentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-5), for: today)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-8), for: yesterday)

    fixture.poller.poll(now: fixture.now)

    #expect(try fixture.envelope().toolLine == "1 subagent working")
}

@MainActor
@Test func malformedSubagentIDNeverCounts() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let parentURL = try fixture.writeRollout(originator: "Codex Desktop")
    let junkURL = try fixture.writeSubagentRollout(
        parentID: fixture.parentID, name: "junk", subagentID: "not-a-uuid"
    )
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-30), for: parentURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-5), for: junkURL)

    fixture.poller.poll(now: fixture.now)

    let envelope = try fixture.envelope()
    #expect(envelope.status == .done)
    #expect(envelope.toolLine == nil)
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
@Test func idleTicksDoNotInflateSeqAndTransitionBumpsOnce() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let rolloutURL = try fixture.writeRollout(originator: "Codex Desktop")
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: rolloutURL)

    fixture.poller.poll(now: fixture.now)
    fixture.poller.poll(now: fixture.now)
    fixture.poller.poll(now: fixture.now)
    var envelope = try fixture.envelope()
    #expect(envelope.seq == 1)
    #expect(envelope.status == .working)

    // working → done: exactly one more write, started preserved
    let started = envelope.started
    fixture.poller.poll(now: fixture.now.addingTimeInterval(60))
    fixture.poller.poll(now: fixture.now.addingTimeInterval(65))
    envelope = try fixture.envelope()
    #expect(envelope.seq == 2)
    #expect(envelope.status == .done)
    #expect(envelope.started == started)
}

@MainActor
@Test func hostileRolloutIDCannotEscapeSpool() throws {
    let fixture = try RolloutFixture()
    defer { fixture.remove() }
    let directoryURL = fixture.sessionsURL
        .appendingPathComponent("2026/04/04", isDirectory: true)
    try fixture.fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let hostileURL = directoryURL.appendingPathComponent("rollout-2026-04-04T12-00-00-evil.jsonl")
    let metadata: [String: Any] = [
        "type": "session_meta",
        "payload": [
            "id": "../decoy",
            "cwd": "/tmp/projects/vibenotch",
            "originator": "Codex Desktop",
        ],
    ]
    try JSONSerialization.data(withJSONObject: metadata).write(to: hostileURL)
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: hostileURL)
    // hostile line has no trailing newline; add one so metadata parses
    let handle = try FileHandle(forWritingTo: hostileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.close()
    try fixture.setModificationDate(fixture.now.addingTimeInterval(-10), for: hostileURL)

    let decoyURL = fixture.rootURL.appendingPathComponent("decoy.json")
    try Data("{}".utf8).write(to: decoyURL)

    fixture.poller.poll(now: fixture.now)

    // nothing may be written outside the spool dir, and the decoy survives
    #expect(try Data(contentsOf: decoyURL) == Data("{}".utf8))
    let spoolContents = (try? fixture.fileManager.contentsOfDirectory(atPath: fixture.spoolURL.path)) ?? []
    #expect(spoolContents.allSatisfy { $0.hasPrefix("codex-app-") || $0.hasPrefix(".codex-app-") })
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
    let parentID = "123e4567-e89b-12d3-a456-426614174000"

    var spoolFileURL: URL {
        spoolURL.appendingPathComponent("codex-app-123e4567.json")
    }

    init() throws {
        rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("Vibenotch-CodexRolloutPoller-\(UUID().uuidString)", isDirectory: true)
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
            "rollout-2026-04-04T12-00-00-\(parentID).jsonl"
        )
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": parentID,
                "cwd": "/tmp/projects/vibenotch",
                "originator": originator,
                "cli_version": "1.2.3"
            ]
        ]
        var data = try JSONSerialization.data(withJSONObject: metadata)
        data.append(contentsOf: Data("\n{\"ignored\":true}\n".utf8))
        try data.write(to: fileURL)
        return fileURL
    }

    func writeSubagentRollout(
        parentID: String,
        name: String,
        subagentID: String = UUID().uuidString.lowercased(),
        day: String = "04"
    ) throws -> URL {
        let directoryURL = sessionsURL
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("04", isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(
            "rollout-2026-04-\(day)T12-00-01-\(subagentID).jsonl"
        )
        let metadata: [String: Any] = [
            "type": "session_meta",
            "payload": [
                "id": subagentID,
                "cwd": "/tmp/projects/vibenotch",
                "originator": "Codex Desktop",
                "thread_source": "subagent",
                "parent_thread_id": parentID,
                "source": ["subagent": ["name": name]],
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

    func envelope(sessionID: String) throws -> SessionEnvelope {
        let fileURL = spoolURL.appendingPathComponent("\(sessionID).json")
        return try JSONDecoder().decode(SessionEnvelope.self, from: Data(contentsOf: fileURL))
    }

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }
}
