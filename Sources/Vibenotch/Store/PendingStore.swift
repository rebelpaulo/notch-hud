import Observation

@Observable
@MainActor
final class PendingStore {
    private(set) var approvals: [PendingApproval] = []

    var current: PendingApproval? {
        approvals.first
    }

    var hasPending: Bool {
        !approvals.isEmpty
    }

    func apply(_ approvals: [PendingApproval]) {
        self.approvals = approvals.sorted { lhs, rhs in
            let lhsCreated = lhs.created ?? ""
            let rhsCreated = rhs.created ?? ""
            if lhsCreated != rhsCreated {
                return lhsCreated < rhsCreated
            }
            return lhs.sessionId < rhs.sessionId
        }
    }

    func dismiss(sessionID: String) {
        approvals.removeAll { $0.sessionId == sessionID }
    }
}
