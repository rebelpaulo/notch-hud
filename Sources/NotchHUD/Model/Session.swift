import Foundation

struct Session: Identifiable, Sendable {
    let id: String
    let agent: String
    let project: String
    var status: SessionStatus
    let detail: String?
    let task: String?
    let prompt: String?
    let toolLine: String?
    let model: String?
    let updatedAt: Date
    let startedAt: Date?
    let seq: Int
    let terminal: TerminalIdentity?
    let source: String?

    init(envelope: SessionEnvelope, updatedAt: Date) {
        id = envelope.id
        agent = envelope.agent
        project = Self.projectName(from: envelope)
        status = envelope.status
        detail = envelope.detail
        task = envelope.task
        prompt = envelope.prompt
        toolLine = envelope.toolLine
        model = envelope.model
        self.updatedAt = updatedAt
        startedAt = envelope.started.flatMap(Self.parseISO8601)
        seq = envelope.seq
        terminal = envelope.terminal
        source = envelope.source
    }

    init?(envelope: SessionEnvelope) {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        guard let updatedAt = fractionalFormatter.date(from: envelope.updated)
            ?? standardFormatter.date(from: envelope.updated)
        else {
            return nil
        }

        self.init(envelope: envelope, updatedAt: updatedAt)
    }

    var displayStatus: DisplayStatus {
        status.displayStatus
    }

    var elapsed: String {
        elapsed(at: Date())
    }

    func elapsed(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(startedAt ?? updatedAt))

        if seconds < 60 {
            return "<1m"
        }
        if seconds < 3_600 {
            return "\(Int(seconds / 60))m"
        }
        if seconds < 86_400 {
            return "\(Int(seconds / 3_600))h"
        }
        return "\(Int(seconds / 86_400))d"
    }

    private static func projectName(from envelope: SessionEnvelope) -> String {
        if let project = envelope.project, !project.isEmpty {
            return project
        }

        if let cwd = envelope.cwd, !cwd.isEmpty {
            let basename = URL(fileURLWithPath: cwd).lastPathComponent
            if !basename.isEmpty {
                return basename
            }
        }

        return envelope.id
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]

        return fractionalFormatter.date(from: value) ?? standardFormatter.date(from: value)
    }
}
