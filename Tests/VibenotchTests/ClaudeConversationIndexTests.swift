import Foundation
import Testing
@testable import Vibenotch

@Test func indexReadsTitleAndWorkingDirectoryFromTheTranscript() throws {
    let fixture = try ConversationFixture()
    defer { fixture.remove() }
    // The directory name encodes the path lossily — both "/" and " " become
    // "-" — so "Claude code" must come from the transcript's own cwd, not from
    // the folder it sits in.
    try fixture.write(
        directoryName: "-Users-mac-Claude-code",
        sessionID: "aaaaaaaa-1111-2222-3333-444444444444",
        lines: [
            #"{"type":"custom-title","customTitle":"Revenge ads meta","sessionId":"aaaaaaaa-1111-2222-3333-444444444444"}"#,
            #"{"type":"user","cwd":"/Users/mac/Claude code","message":{}}"#,
        ]
    )

    let conversations = ClaudeConversationIndex(homeURL: fixture.home).recentConversations()

    #expect(conversations.count == 1)
    let conversation = try #require(conversations.first)
    #expect(conversation.title == "Revenge ads meta")
    #expect(conversation.directory == "/Users/mac/Claude code")
    #expect(conversation.project == "Claude code")
    #expect(conversation.id == "aaaaaaaa-1111-2222-3333-444444444444")
}

@Test func indexTakesTheLatestTitleWhenAConversationWasRenamed() throws {
    // Renaming appends another customTitle record; stopping at the first one
    // publishes the name the user deliberately changed away from.
    let fixture = try ConversationFixture()
    defer { fixture.remove() }
    try fixture.write(
        directoryName: "-Users-mac-project",
        sessionID: "eeeeeeee-1111-2222-3333-444444444444",
        lines: [
            #"{"type":"custom-title","customTitle":"Old name"}"#,
            #"{"type":"user","cwd":"/Users/mac/project"}"#,
            #"{"type":"custom-title","customTitle":"Revenge ads meta"}"#,
        ]
    )

    let conversation = try #require(
        ClaudeConversationIndex(homeURL: fixture.home).recentConversations().first
    )

    #expect(conversation.title == "Revenge ads meta")
}

@Test func indexSkipsConversationsWithNoTitle() throws {
    let fixture = try ConversationFixture()
    defer { fixture.remove() }
    // The Claude app shows these under an auto-generated name the user has
    // never seen, so listing them on the phone is noise they cannot act on.
    try fixture.write(
        directoryName: "-Users-mac-project",
        sessionID: "bbbbbbbb-1111-2222-3333-444444444444",
        lines: [#"{"type":"user","cwd":"/Users/mac/project","message":{}}"#]
    )

    #expect(ClaudeConversationIndex(homeURL: fixture.home).recentConversations().isEmpty)
}

@Test func mostRecentDirectoryIgnoresTheTitleFilter() throws {
    // The resumable list hides untitled conversations because their
    // auto-generated names mean nothing to a reader. "Where was I working"
    // has no such requirement — and taking the directory from the filtered
    // list left a fresh install with no project to start in at all.
    let fixture = try ConversationFixture()
    defer { fixture.remove() }
    try fixture.write(
        directoryName: "-Users-mac-fresh",
        sessionID: "ffffffff-1111-2222-3333-444444444444",
        lines: [#"{"type":"user","cwd":"/Users/mac/fresh"}"#]
    )

    let index = ClaudeConversationIndex(homeURL: fixture.home)

    #expect(index.recentConversations().isEmpty)
    #expect(index.mostRecentDirectory() == "/Users/mac/fresh")
}

@Test func mostRecentDirectoryIsNilWithNoTranscriptsAtAll() throws {
    let fixture = try ConversationFixture()
    defer { fixture.remove() }

    #expect(ClaudeConversationIndex(homeURL: fixture.home).mostRecentDirectory() == nil)
}

@Test func indexReturnsMostRecentlyTouchedFirst() throws {
    let fixture = try ConversationFixture()
    defer { fixture.remove() }
    for (index, name) in ["older", "newer"].enumerated() {
        let url = try fixture.write(
            directoryName: "-Users-mac-project",
            sessionID: "cccccccc-0000-0000-0000-00000000000\(index)",
            lines: [
                #"{"customTitle":"\#(name)"}"#,
                #"{"cwd":"/Users/mac/project"}"#,
            ]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index) * 1_000)],
            ofItemAtPath: url.path
        )
    }

    let titles = ClaudeConversationIndex(homeURL: fixture.home).recentConversations().map(\.title)

    #expect(titles == ["newer", "older"])
}

@Test func indexHonoursTheLimit() throws {
    let fixture = try ConversationFixture()
    defer { fixture.remove() }
    for index in 0..<5 {
        _ = try fixture.write(
            directoryName: "-Users-mac-project",
            sessionID: "dddddddd-0000-0000-0000-00000000000\(index)",
            lines: [#"{"customTitle":"c\#(index)"}"#, #"{"cwd":"/Users/mac/project"}"#]
        )
    }

    #expect(ClaudeConversationIndex(homeURL: fixture.home).recentConversations(limit: 2).count == 2)
}

private final class ConversationFixture {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    func write(directoryName: String, sessionID: String, lines: [String]) throws -> URL {
        let directory = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(sessionID).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
