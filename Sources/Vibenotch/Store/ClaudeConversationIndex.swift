import Foundation

/// A past Claude conversation that can be resumed.
///
/// Resuming one also brings Remote Control back: `claude --resume` reconnects
/// to the Remote Control session recorded in that conversation, which is the
/// whole point — a conversation showing "Disconnected" in the Claude app has
/// no way back from the phone, only from the machine it ran on.
struct ClaudeConversation: Equatable, Sendable {
    let id: String
    let title: String
    let directory: String
    let lastActive: Date

    var project: String {
        URL(fileURLWithPath: directory).lastPathComponent
    }
}

/// Reads `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`.
///
/// The directory name is a lossy encoding of the path (both `/` and spaces
/// become `-`), so the working directory is taken from the transcript's own
/// `cwd` field instead — it is the only unambiguous source, and the resume has
/// to run in the right directory.
struct ClaudeConversationIndex: Sendable {
    /// How many of the most recently touched transcripts to parse. Sorting by
    /// modification date first means the scan cost does not grow with the
    /// hundreds of old conversations that will never be resumed.
    static let scanLimit = 40

    /// Lines to read per transcript. The title and cwd appear at the top; a
    /// long conversation is megabytes, and none of it is needed here.
    static let lineLimit = 60

    let projectsURL: URL

    /// `FileManager.default` rather than an injected instance: this runs off
    /// the main actor, and the shared instance is the one Apple documents as
    /// safe to use concurrently for these read-only calls.
    private var fileManager: FileManager { .default }

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        projectsURL = homeURL.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Most recent first. Only titled conversations: an untitled one shows up
    /// in the Claude app as an auto-generated name the user has never seen, so
    /// listing it on the phone would be noise they cannot recognise.
    func recentConversations(limit: Int = 12) -> [ClaudeConversation] {
        transcriptURLs()
            .prefix(Self.scanLimit)
            .compactMap(conversation(at:))
            .prefix(limit)
            .map { $0 }
    }

    private func transcriptURLs() -> [URL] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let transcripts = directories.flatMap { directory -> [URL] in
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ))?.filter { $0.pathExtension == "jsonl" } ?? []
        }

        // Stat once per file, not once per comparison: sorting on a computed
        // property turns n files into n·log n stat calls, which is the whole
        // cost on a machine with a long history.
        return transcripts
            .map { (url: $0, date: modificationDate(of: $0)) }
            .sorted { $0.date > $1.date }
            .map(\.url)
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private func conversation(at url: URL) -> ClaudeConversation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 256 KB covers the first lines of any transcript without pulling a
        // multi-megabyte conversation into memory to read two fields.
        guard let chunk = try? handle.read(upToCount: 256 * 1024),
              let text = String(data: chunk, encoding: .utf8)
        else { return nil }

        var title: String?
        var directory: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(Self.lineLimit) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            // Last title wins: renaming a conversation appends another
            // customTitle record, so stopping at the first one publishes the
            // name the user changed away from.
            if let value = object["customTitle"] as? String, !value.isEmpty {
                title = value
            }
            if directory == nil, let value = object["cwd"] as? String, !value.isEmpty {
                directory = value
            }
        }

        guard let title, let directory else { return nil }
        return ClaudeConversation(
            id: url.deletingPathExtension().lastPathComponent,
            title: title,
            directory: directory,
            lastActive: modificationDate(of: url)
        )
    }
}
