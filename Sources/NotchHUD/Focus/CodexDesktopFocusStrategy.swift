struct CodexDesktopFocusStrategy: FocusStrategy {
    static let bundleIdentifier = "com.openai.codex"

    private let workspace: any ClaudeDesktopWorkspace

    init(workspace: any ClaudeDesktopWorkspace = SystemClaudeDesktopWorkspace()) {
        self.workspace = workspace
    }

    func canHandle(_ session: Session) -> Bool {
        session.source == "codex-desktop"
    }

    func focus(_ session: Session) throws {
        guard let application = workspace.runningApplications(
            bundleIdentifier: Self.bundleIdentifier
        ).first else {
            throw FocusError.notFound
        }

        application.activate()
    }
}
