protocol FocusStrategy: Sendable {
    func canHandle(_ session: Session) -> Bool
    func focus(_ session: Session) throws
}

enum FocusError: Error, Equatable {
    case notFound
    case permissionDenied(String)
    case scriptFailed(String)
}
