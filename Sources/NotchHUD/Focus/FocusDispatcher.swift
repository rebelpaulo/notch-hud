import Foundation

@MainActor
final class FocusDispatcher {
    private let strategies: [any FocusStrategy]

    init(strategies: [any FocusStrategy] = [
        ClaudeDesktopFocusStrategy(),
        TerminalAppStrategy(),
        ITerm2Strategy(),
        WezTermStrategy(),
        KittyStrategy()
    ]) {
        self.strategies = strategies
    }

    func strategy(for session: Session) -> (any FocusStrategy)? {
        strategies.first(where: { $0.canHandle(session) })
    }

    func focus(_ session: Session) async -> Result<Void, FocusError> {
        guard let strategy = strategy(for: session) else {
            return .failure(.notFound)
        }

        do {
            try await Task.detached {
                try strategy.focus(session)
            }.value
            return .success(())
        } catch let error as FocusError {
            return .failure(error)
        } catch {
            return .failure(.scriptFailed(error.localizedDescription))
        }
    }
}
