import Observation

@Observable
@MainActor
final class SessionStore {
    private(set) var sessions: [Session] = []
    private var sourceSessions: [Session] = []
    private var pendingSessionIDs = Set<String>()

    func apply(_ sessions: [Session]) {
        sourceSessions = sessions
        rebuildSessions()
    }

    func markPendingApprovals(sessionIDs: Set<String>) {
        pendingSessionIDs = Set(sessionIDs.flatMap { sessionID in
            [sessionID, "claude-\(sessionID)"]
        })
        rebuildSessions()
    }

    var sessionsWithoutPendingOverlay: [Session] {
        sourceSessions
    }

    private func rebuildSessions() {
        sessions = sourceSessions.map { session in
            var session = session
            if pendingSessionIDs.contains(session.id) {
                session.status = .needs_me
            }
            return session
        }.sorted { lhs, rhs in
            let lhsRank = Self.sortRank(for: lhs.displayStatus)
            let rhsRank = Self.sortRank(for: rhs.displayStatus)

            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsCanFocus = lhs.terminal?.tty != nil || lhs.source == "claude-desktop"
            let rhsCanFocus = rhs.terminal?.tty != nil || rhs.source == "claude-desktop"
            if lhsCanFocus != rhsCanFocus {
                return lhsCanFocus
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    var counts: (working: Int, needsMe: Int, done: Int) {
        var working = 0
        var needsMe = 0
        var done = 0

        for session in sessions {
            switch session.displayStatus {
            case .working:
                working += 1
            case .needsMe:
                needsMe += 1
            case .done:
                done += 1
            case .idle:
                break
            }
        }

        return (working, needsMe, done)
    }

    var total: Int {
        sessions.count
    }

    private static func sortRank(for status: DisplayStatus) -> Int {
        switch status {
        case .needsMe:
            0
        case .working:
            1
        case .done:
            2
        case .idle:
            3
        }
    }
}
