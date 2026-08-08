import Foundation
import Testing
@testable import Vibenotch

@Test func pendingApprovalDecodesEditBody() throws {
    let approval = try decodePending(
        """
        {
          "schema": 1,
          "sessionId": "edit-session",
          "tool": "Edit",
          "cwd": "/tmp/vibenotch",
          "created": "2026-07-22T12:00:00Z",
          "summary": "Edit Sources/App.swift",
          "bash": null,
          "edit": {"file":"Sources/App.swift","old":"let old = 1","new":"let new = 2"},
          "write": null
        }
        """
    )

    #expect(approval.edit?.file == "Sources/App.swift")
    #expect(approval.edit?.old == "let old = 1")
    #expect(approval.edit?.new == "let new = 2")
    #expect(approval.projectName == "vibenotch")
}

@Test func pendingApprovalDecodesWriteBody() throws {
    let approval = try decodePending(
        """
        {
          "schema": 1,
          "sessionId": "write-session",
          "tool": "Write",
          "summary": "Write README.md",
          "write": {"file":"README.md","content":"Hello"}
        }
        """
    )

    #expect(approval.write?.file == "README.md")
    #expect(approval.write?.content == "Hello")
    #expect(approval.bash == nil)
}

@Test func pendingApprovalDecodesBashBody() throws {
    let approval = try decodePending(
        """
        {
          "schema": 1,
          "sessionId": "bash-session",
          "tool": "Bash",
          "bash": {"command":"git status --short"}
        }
        """
    )

    #expect(approval.bash?.command == "git status --short")
    #expect(approval.edit == nil)
}

@Test func pendingApprovalToleratesMissingOptionalFields() throws {
    let approval = try decodePending(
        """
        {
          "sessionId": "minimal-session",
          "tool": "NotebookEdit",
          "edit": {}
        }
        """
    )

    #expect(approval.schema == nil)
    #expect(approval.cwd == nil)
    #expect(approval.summary == nil)
    #expect(approval.edit?.file == nil)
    #expect(approval.edit?.old == nil)
    #expect(approval.edit?.new == nil)
}

@Test func approvalDecisionEncodesExpectedFileShapeAndRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibenotch-decision-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let decision = ApprovalDecision(decision: .allow, scope: .session)
    let writer = ApprovalDecisionWriter(decisionsURL: directory)
    try writer.write(decision, for: "decision-session")

    let data = try Data(contentsOf: directory.appendingPathComponent("decision-session.json"))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

    #expect(object == ["decision": "allow", "scope": "session"])
    #expect(try JSONDecoder().decode(ApprovalDecision.self, from: data) == decision)
}

private func decodePending(_ json: String) throws -> PendingApproval {
    try JSONDecoder().decode(PendingApproval.self, from: Data(json.utf8))
}
