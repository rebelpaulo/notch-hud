struct TerminalIdentity: Codable, Sendable {
    let termProgram: String?
    let tty: String?
    let itermSessionId: String?
    let weztermPane: String?
    let kittyWindowId: String?
    let windowId: String?
}
