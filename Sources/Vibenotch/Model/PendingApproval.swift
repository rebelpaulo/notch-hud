import Foundation

struct PendingApproval: Codable, Identifiable, Equatable, Sendable {
    struct BashBody: Codable, Equatable, Sendable {
        let command: String?
    }

    struct EditBody: Codable, Equatable, Sendable {
        let file: String?
        let old: String?
        let new: String?
    }

    struct WriteBody: Codable, Equatable, Sendable {
        let file: String?
        let content: String?
    }

    let schema: Int?
    let sessionId: String
    let tool: String
    let cwd: String?
    let created: String?
    let summary: String?
    let bash: BashBody?
    let edit: EditBody?
    let write: WriteBody?

    var id: String { sessionId }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "Unknown project" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

struct ApprovalDecision: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Sendable {
        case allow
        case deny
    }

    enum Scope: String, Codable, Sendable {
        case once
        case session
    }

    let decision: Decision
    let scope: Scope
}

struct ApprovalDecisionWriter {
    let decisionsURL: URL
    var sessionAllowURL: URL?
    var fileManager: FileManager = .default

    init(
        decisionsURL: URL,
        sessionAllowURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.decisionsURL = decisionsURL
        self.sessionAllowURL = sessionAllowURL
        self.fileManager = fileManager
    }

    func write(_ decision: ApprovalDecision, for sessionID: String) throws {
        try validate(sessionID: sessionID)

        try fileManager.createDirectory(
            at: decisionsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: decisionsURL.path
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(decision)
        let destination = decisionsURL.appendingPathComponent("\(sessionID).json")
        try data.write(to: destination, options: [.atomic])
    }

    func writeSessionAllowance(for approval: PendingApproval) throws {
        guard let sessionAllowURL else { return }
        try validate(sessionID: approval.sessionId)

        let toolClass: String
        if approval.tool == "Bash" {
            let command = approval.bash?.command ?? ""
            let firstWord = command
                .split(whereSeparator: { $0.isWhitespace })
                .first
                .map(String.init) ?? ""
            toolClass = "Bash:\(firstWord)"
        } else {
            toolClass = approval.tool
        }

        try fileManager.createDirectory(
            at: sessionAllowURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: sessionAllowURL.path
        )

        let destination = sessionAllowURL.appendingPathComponent(approval.sessionId)
        let existing = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        let existingClasses = Set(existing.split(separator: "\n").map(String.init))
        guard !existingClasses.contains(toolClass) else { return }

        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let data = Data((existing + separator + toolClass + "\n").utf8)
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
    }

    private func validate(sessionID: String) throws {
        guard !sessionID.isEmpty,
              sessionID != ".",
              sessionID != "..",
              !sessionID.contains("/")
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }
}
