import Foundation
import Testing
@testable import Vibenotch

@MainActor
@Test func resumeCommandCarriesRemoteControlAndTheRightDirectory() {
    let conversation = ClaudeConversation(
        id: "aaaaaaaa-1111-2222-3333-444444444444",
        title: "Revenge ads meta",
        directory: "/Users/mac/Claude code",
        lastActive: Date(timeIntervalSince1970: 0)
    )

    let command = TerminalConversationResumer.command(for: conversation)

    // The space in "Claude code" is exactly why this is quoted; an unquoted
    // path would cd into "/Users/mac/Claude" and resume in the wrong place.
    #expect(command == "cd '/Users/mac/Claude code' && claude --remote-control --resume 'aaaaaaaa-1111-2222-3333-444444444444'")
}

@MainActor
@Test func shellQuotingSurvivesAQuoteInThePath() {
    let quoted = TerminalConversationResumer.shellQuoted("/Users/mac/it's here")

    #expect(quoted == #"'/Users/mac/it'\''s here'"#)
}

@MainActor
@Test func appleScriptEscapingSurvivesQuotesAndBackslashes() {
    let escaped = TerminalConversationResumer.escapedForAppleScript(#"a "b" c\d"#)

    #expect(escaped == #"a \"b\" c\\d"#)
}

@MainActor
@Test func resumeReportsFailureRatherThanClaimingSuccess() {
    var resumer = TerminalConversationResumer()
    resumer.runScript = { _ in throw FocusError.permissionDenied("nope") }

    let ok = resumer.resume(
        ClaudeConversation(id: "x", title: "t", directory: "/tmp", lastActive: Date())
    )

    #expect(!ok)
}
