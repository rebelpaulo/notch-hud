struct WezTermStrategy: FocusStrategy {
    func canHandle(_ session: Session) -> Bool {
        false
    }

    func focus(_ session: Session) throws {
        throw FocusError.notFound
    }
}
