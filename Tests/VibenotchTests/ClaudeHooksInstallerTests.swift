import Foundation
import Testing

@Test func claudeHooksInstallerAddsHooksAdditivelyAndIsIdempotent() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let settings = scratch.appendingPathComponent("claude/settings.json")
    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)

    let existing = """
    {
      "permissions": { "defaultMode": "auto" },
      "hooks": {
        "PreToolUse": [
          { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
        ]
      }
    }
    """
    try existing.write(to: settings, atomically: true, encoding: .utf8)

    let first = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(first.status == 0)
    #expect(first.output.contains("changed"))

    let afterFirst = try Data(contentsOf: settings)
    let json = try #require(JSONSerialization.jsonObject(with: afterFirst) as? [String: Any])

    // Unrelated top-level + unrelated hook entry both survive untouched.
    let permissions = try #require(json["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "auto")

    let hooks = try #require(json["hooks"] as? [String: Any])
    let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(preToolUse.count == 2)
    #expect(preToolUse.contains { ($0["matcher"] as? String) == "Bash" })

    let hookPath = prefix.appendingPathComponent("bin/vibenotch-claude-hook").path
    let ourGroup = try #require(preToolUse.first { ($0["matcher"] as? String) == "*" })
    let ourGroupHooks = try #require(ourGroup["hooks"] as? [[String: Any]])
    #expect(ourGroupHooks.first?["command"] as? String == "\(hookPath) tool")

    let expected: [(event: String, verb: String)] = [
        ("UserPromptSubmit", "working"),
        ("Stop", "done"),
        ("Notification", "notify"),
        ("SessionEnd", "remove"),
    ]
    for (event, verb) in expected {
        let entries = try #require(hooks[event] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["matcher"] == nil)
        let entryHooks = try #require(entries[0]["hooks"] as? [[String: Any]])
        #expect(entryHooks.first?["command"] as? String == "\(hookPath) \(verb)")
    }

    let backupsAfterFirst = try claudeHooksBackupNames(nextTo: settings)
    #expect(backupsAfterFirst.count == 1)

    let second = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(second.status == 0)
    #expect(second.output.contains("skipped"))
    #expect(try Data(contentsOf: settings) == afterFirst)
    #expect(try claudeHooksBackupNames(nextTo: settings) == backupsAfterFirst)
}

@Test func claudeHooksInstallerCreatesSettingsWhenMissing() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let settings = scratch.appendingPathComponent("claude/settings.json")
    #expect(!FileManager.default.fileExists(atPath: settings.path))

    let result = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(result.status == 0)
    #expect(FileManager.default.fileExists(atPath: settings.path))
    #expect(try claudeHooksBackupNames(nextTo: settings).isEmpty)

    let json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    )
    let hooks = try #require(json["hooks"] as? [String: Any])
    #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
}

@Test func claudeHooksInstallerUninstallRemovesOnlyOurEntries() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let settings = scratch.appendingPathComponent("claude/settings.json")
    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "hooks": {
        "PreToolUse": [
          { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
        ]
      }
    }
    """.write(to: settings, atomically: true, encoding: .utf8)

    _ = try runClaudeHooksInstaller(prefix: prefix, settings: settings)

    let result = try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true)
    #expect(result.status == 0)
    #expect(result.output.contains("changed"))

    let json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    )
    let hooks = try #require(json["hooks"] as? [String: Any])
    let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(preToolUse.count == 1)
    #expect(preToolUse[0]["matcher"] as? String == "Bash")
    #expect(hooks["UserPromptSubmit"] == nil)

    // Idempotent: nothing left to remove on a second uninstall.
    let second = try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true)
    #expect(second.status == 0)
    #expect(second.output.contains("skipped"))
}

@Test func claudeHooksUninstallLeavesAForeignSettingsFileByteForByte() throws {
    // Re-serializing on a no-op rewrote a hand-formatted settings.json and
    // reported "changed", so an uninstall with nothing of ours to remove still
    // reflowed the user's file and left a backup behind.
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let settings = scratch.appendingPathComponent("settings.json")
    let original = """
    {
        "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "rtk hook claude"}]}]},
            "otherKey": 1
    }
    """
    try original.write(to: settings, atomically: true, encoding: .utf8)

    let result = try runClaudeHooksInstaller(
        prefix: scratch.appendingPathComponent("prefix"),
        settings: settings,
        uninstall: true
    )

    #expect(result.status == 0)
    #expect(result.output.contains("skipped"))
    #expect(try String(contentsOf: settings, encoding: .utf8) == original)
    #expect(try claudeHooksBackupNames(nextTo: settings).isEmpty)
}

private func claudeHooksRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeClaudeHooksScratch() throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibenotch-claude-hooks-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
}

private func runClaudeHooksInstaller(
    prefix: URL,
    settings: URL,
    uninstall: Bool = false
) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    var arguments = [claudeHooksRepoRoot().appendingPathComponent("scripts/install-claude-hooks.sh").path]
    if uninstall {
        arguments.append("--uninstall")
    }
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["VIBEVIBENOTCH_INSTALL_PREFIX"] = prefix.path
    environment["VIBENOTCH_INSTALL_CLAUDE_SETTINGS"] = settings.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func claudeHooksBackupNames(nextTo file: URL) throws -> [String] {
    let prefix = file.lastPathComponent + ".bak."
    let directory = file.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(prefix) }
        .sorted()
}
