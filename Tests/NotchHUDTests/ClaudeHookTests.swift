import Foundation
import Testing

@Test func claudeHookRefinesProjectFromRepoUnderWorkspaceRoot() throws {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-hook-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    // workspace root containing a git repo, session cwd = workspace root
    let workspace = scratch.appendingPathComponent("workspace", isDirectory: true)
    let repoGit = workspace.appendingPathComponent("my-repo/.git", isDirectory: true)
    try FileManager.default.createDirectory(at: repoGit, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: scratch.appendingPathComponent("home"),
        withIntermediateDirectories: true
    )

    let home = scratch.appendingPathComponent("home")
    let workspacePath = workspace.path

    // working: project starts as the workspace folder name
    try runHook(
        "working",
        payload: #"{"session_id":"s1","cwd":"\#(workspacePath)","prompt":"do things"}"#,
        home: home
    )
    var envelope = try hookPayload(id: "claude-s1", home: home)
    #expect(envelope["project"] as? String == "workspace")

    // Edit inside workspace/my-repo → project refined to the repo
    let editPayload = #"{"session_id":"s1","cwd":"\#(workspacePath)","tool_name":"Edit","tool_input":{"file_path":"\#(workspacePath)/my-repo/Sources/App.swift"}}"#
    try runHook("tool", payload: editPayload, home: home)
    envelope = try hookPayload(id: "claude-s1", home: home)
    #expect(envelope["project"] as? String == "my-repo")
    #expect(envelope["toolLine"] as? String == "Edit App.swift")

    // Bash cd into the repo also refines (quoted path with spaces in workspace)
    let cdPayload = #"{"session_id":"s2","cwd":"\#(workspacePath)","tool_name":"Bash","tool_input":{"command":"cd \"\#(workspacePath)/my-repo\" && swift build"}}"#
    try runHook("tool", payload: cdPayload, home: home)
    envelope = try hookPayload(id: "claude-s2", home: home)
    #expect(envelope["project"] as? String == "my-repo")

    // paths outside any repo (no .git) keep the cwd fallback
    let plainPayload = #"{"session_id":"s3","cwd":"\#(workspacePath)","tool_name":"Edit","tool_input":{"file_path":"\#(workspacePath)/loose-file.md"}}"#
    try runHook("tool", payload: plainPayload, home: home)
    envelope = try hookPayload(id: "claude-s3", home: home)
    #expect(envelope["project"] as? String == "workspace")
}

private func runHook(_ status: String, payload: String, home: URL) throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [root.appendingPathComponent("scripts/notch-claude-hook").path, status]

    var environment = ProcessInfo.processInfo.environment
    environment["NOTCH_HUD_HOME"] = home.path
    environment["NOTCH_HUD_TTY"] = ""
    process.environment = environment

    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    stdin.fileHandleForWriting.write(Data(payload.utf8))
    stdin.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func hookPayload(id: String, home: URL) throws -> [String: Any] {
    let url = home.appendingPathComponent("sessions/\(id).json")
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
