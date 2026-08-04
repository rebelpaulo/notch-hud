import Foundation
import Testing

@Test func claudeHookKeepsRefinedProjectThroughLifecycle() throws {
    let fixture = try HookFixture()
    defer { fixture.remove() }

    try runHook(
        "working",
        payload: try hookJSON(sessionID: "lifecycle", cwd: fixture.workspace.path, prompt: "do things"),
        home: fixture.home
    )
    var envelope = try hookPayload(id: "claude-lifecycle", home: fixture.home)
    #expect(envelope["project"] as? String == "workspace with spaces")

    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "lifecycle",
            cwd: fixture.workspace.path,
            toolName: "Edit",
            toolInput: ["file_path": fixture.repo.appendingPathComponent("Sources/App.swift").path]
        ),
        home: fixture.home
    )
    envelope = try hookPayload(id: "claude-lifecycle", home: fixture.home)
    #expect(envelope["project"] as? String == "my-repo")
    #expect(envelope["toolLine"] as? String == "Edit App.swift")

    try runHook(
        "done",
        payload: try hookJSON(sessionID: "lifecycle", cwd: fixture.workspace.path),
        home: fixture.home
    )
    envelope = try hookPayload(id: "claude-lifecycle", home: fixture.home)
    #expect(envelope["project"] as? String == "my-repo")

    try runHook(
        "notify",
        payload: try hookJSON(
            sessionID: "lifecycle",
            cwd: fixture.workspace.path,
            extra: ["message": "Ready"]
        ),
        home: fixture.home
    )
    envelope = try hookPayload(id: "claude-lifecycle", home: fixture.home)
    #expect(envelope["project"] as? String == "my-repo")
    #expect(envelope["status"] as? String == "needs_me")
}

@Test func claudeHookRejectsTraversalAndNestedRepos() throws {
    let fixture = try HookFixture()
    defer { fixture.remove() }

    for (index, path) in [
        fixture.repo.appendingPathComponent("../loose.txt").path,
        fixture.repo.appendingPathComponent("..").path,
        fixture.repo.path + "/./Sources/App.swift",
    ].enumerated() {
        let sessionID = "traversal-\(index)"
        try initialize(sessionID, cwd: fixture.workspace.path, fixture: fixture)
        try runHook(
            "tool",
            payload: try hookJSON(
                sessionID: sessionID,
                cwd: fixture.workspace.path,
                toolName: "Edit",
                toolInput: ["file_path": path]
            ),
            home: fixture.home
        )
        let envelope = try hookPayload(id: "claude-\(sessionID)", home: fixture.home)
        #expect(envelope["project"] as? String == "workspace with spaces")
    }

    let repoCwd = fixture.scratch.appendingPathComponent("app", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repoCwd.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    let vendor = repoCwd.appendingPathComponent("vendor", isDirectory: true)
    try FileManager.default.createDirectory(
        at: vendor.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    try initialize("nested", cwd: repoCwd.path, fixture: fixture)
    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "nested",
            cwd: repoCwd.path,
            toolName: "Edit",
            toolInput: ["file_path": vendor.appendingPathComponent("File.swift").path]
        ),
        home: fixture.home
    )
    let nestedEnvelope = try hookPayload(id: "claude-nested", home: fixture.home)
    #expect(nestedEnvelope["project"] as? String == "app")
}

@Test func claudeHookParsesOnlyConservativeCdTargets() throws {
    let fixture = try HookFixture()
    defer { fixture.remove() }

    let namedRepo = fixture.workspace.appendingPathComponent("-named-repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: namedRepo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    let tildeWorkspace = fixture.home.appendingPathComponent("tilde-workspace", isDirectory: true)
    let tildeRepo = tildeWorkspace.appendingPathComponent("my-repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: tildeRepo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )

    let refinements: [(String, String, String)] = [
        ("leading", fixture.workspace.path, "   cd \"\(fixture.repo.path)\" || exit"),
        ("relative", fixture.workspace.path, "cd ./my-repo; pwd"),
        ("physical", fixture.workspace.path, "cd -P my-repo && pwd"),
        ("logical", fixture.workspace.path, "cd -L my-repo\npwd"),
        ("double-dash", fixture.workspace.path, "cd -- -named-repo && pwd"),
        ("tilde", tildeWorkspace.path, "cd ~/tilde-workspace/my-repo"),
    ]
    for (sessionID, cwd, command) in refinements {
        try initialize(sessionID, cwd: cwd, fixture: fixture)
        try runHook(
            "tool",
            payload: try hookJSON(
                sessionID: sessionID,
                cwd: cwd,
                toolName: "Bash",
                toolInput: ["command": command]
            ),
            home: fixture.home
        )
        let envelope = try hookPayload(id: "claude-\(sessionID)", home: fixture.home)
        let expected = sessionID == "double-dash" ? "-named-repo" : "my-repo"
        #expect(envelope["project"] as? String == expected)
    }

    let rejected = [
        "cd \"\(fixture.repo.path);archive\"",
        "cd \"\(fixture.repo.path) && build",
        "cd -",
        "cd",
        "cd\tmy-repo",
        "cd $HOME/workspace/my-repo",
        "cd my\\-repo",
        "cd my-repo$(pwd)",
        "cd my-repo(build)",
    ]
    for (index, command) in rejected.enumerated() {
        let sessionID = "rejected-\(index)"
        try initialize(sessionID, cwd: fixture.workspace.path, fixture: fixture)
        try runHook(
            "tool",
            payload: try hookJSON(
                sessionID: sessionID,
                cwd: fixture.workspace.path,
                toolName: "Bash",
                toolInput: ["command": command]
            ),
            home: fixture.home
        )
        let envelope = try hookPayload(id: "claude-\(sessionID)", home: fixture.home)
        #expect(envelope["project"] as? String == "workspace with spaces")
    }
}

@Test func claudeHookRefinesProjectFromGrepPath() throws {
    let fixture = try HookFixture()
    defer { fixture.remove() }

    try initialize("grep", cwd: fixture.workspace.path, fixture: fixture)
    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "grep",
            cwd: fixture.workspace.path,
            toolName: "Grep",
            toolInput: ["pattern": "canFocus", "path": fixture.repo.appendingPathComponent("Sources").path]
        ),
        home: fixture.home
    )
    let envelope = try hookPayload(id: "claude-grep", home: fixture.home)
    #expect(envelope["project"] as? String == "my-repo")

    // relative search paths resolve against cwd
    try initialize("grep-rel", cwd: fixture.workspace.path, fixture: fixture)
    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "grep-rel",
            cwd: fixture.workspace.path,
            toolName: "Glob",
            toolInput: ["pattern": "*.swift", "path": "my-repo/Sources"]
        ),
        home: fixture.home
    )
    let relative = try hookPayload(id: "claude-grep-rel", home: fixture.home)
    #expect(relative["project"] as? String == "my-repo")
}

@Test func claudeHookUsesNotebookPathAndHandlesCwdEdges() throws {
    let fixture = try HookFixture()
    defer { fixture.remove() }

    try initialize("notebook", cwd: fixture.workspace.path, fixture: fixture)
    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "notebook",
            cwd: fixture.workspace.path,
            toolName: "NotebookEdit",
            toolInput: ["notebook_path": fixture.repo.appendingPathComponent("Notes.ipynb").path]
        ),
        home: fixture.home
    )
    var envelope = try hookPayload(id: "claude-notebook", home: fixture.home)
    #expect(envelope["project"] as? String == "my-repo")
    #expect(envelope["toolLine"] as? String == "NotebookEdit Notes.ipynb")

    try initialize("trailing", cwd: fixture.workspace.path + "/", fixture: fixture)
    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "trailing",
            cwd: fixture.workspace.path + "/",
            toolName: "Read",
            toolInput: ["file_path": fixture.repo.appendingPathComponent("README.md").path]
        ),
        home: fixture.home
    )
    envelope = try hookPayload(id: "claude-trailing", home: fixture.home)
    #expect(envelope["project"] as? String == "my-repo")

    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "missing-cwd",
            toolName: "Read",
            toolInput: ["file_path": fixture.repo.appendingPathComponent("README.md").path]
        ),
        home: fixture.home
    )
    envelope = try hookPayload(id: "claude-missing-cwd", home: fixture.home)
    #expect(envelope["project"] == nil)

    try runHook(
        "tool",
        payload: try hookJSON(
            sessionID: "root-cwd",
            cwd: "/",
            toolName: "Read",
            toolInput: ["file_path": fixture.repo.appendingPathComponent("README.md").path]
        ),
        home: fixture.home
    )
    envelope = try hookPayload(id: "claude-root-cwd", home: fixture.home)
    #expect(envelope["project"] as? String != "my-repo")
}

private struct HookFixture {
    let scratch: URL
    let home: URL
    let workspace: URL
    let repo: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hook-test-\(UUID().uuidString)", isDirectory: true)
        home = scratch.appendingPathComponent("home", isDirectory: true)
        workspace = home.appendingPathComponent("workspace with spaces", isDirectory: true)
        repo = workspace.appendingPathComponent("my-repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }
}

private func initialize(_ sessionID: String, cwd: String, fixture: HookFixture) throws {
    try runHook(
        "working",
        payload: try hookJSON(sessionID: sessionID, cwd: cwd, prompt: "work"),
        home: fixture.home
    )
}

private func hookJSON(
    sessionID: String,
    cwd: String? = nil,
    prompt: String? = nil,
    toolName: String? = nil,
    toolInput: [String: Any]? = nil,
    extra: [String: Any] = [:]
) throws -> String {
    var object = extra
    object["session_id"] = sessionID
    if let cwd { object["cwd"] = cwd }
    if let prompt { object["prompt"] = prompt }
    if let toolName { object["tool_name"] = toolName }
    if let toolInput { object["tool_input"] = toolInput }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try #require(String(data: data, encoding: .utf8))
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
    environment["HOME"] = home.path
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
