struct ITerm2Strategy: FocusStrategy {
    func canHandle(_ session: Session) -> Bool {
        false
    }

    func focus(_ session: Session) throws {
        throw FocusError.notFound
    }
}
