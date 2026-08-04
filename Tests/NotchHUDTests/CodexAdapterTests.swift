import Foundation
import Testing

@Test func codexNotifyEmitsDoneWithExplicitSessionIdentity() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // notify is update-only: seed the session the way the shim would.
    _ = try runCodexScript(
        "notch-emit",
        arguments: ["codex-explicit", "codex", "working", "--source", "codex"],
        home: scratch
    )

    let payload = #"{"type":"agent-turn-complete","thread-id":"thread-ignored"}"#
    let result = try runCodexScript(
        "notch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: ["NOTCH_CODEX_SESSION_ID": "codex-explicit"]
    )

    #expect(result.status == 0)
    let envelope = try codexPayload(id: "codex-explicit", home: scratch)
    #expect(envelope["status"] as? String == "done")
    #expect(envelope["source"] as? String == "codex")
    #expect(envelope["id"] as? String == "codex-explicit")
}

@Test func codexNotifyEmitsNeedsMeForApprovalPayload() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    _ = try runCodexScript(
        "notch-emit",
        arguments: ["codex-approval-thread", "codex", "working", "--source", "codex"],
        home: scratch
    )

    let payload = #"{"type":"exec-approval-request","conversation_id":"approval-thread"}"#
    let result = try runCodexScript("notch-codex-notify", arguments: [payload], home: scratch)

    #expect(result.status == 0)
    let envelope = try codexPayload(id: "codex-approval-thread", home: scratch)
    #expect(envelope["status"] as? String == "needs_me")
    #expect(envelope["source"] as? String == "codex")
}

@Test func codexNotifyIgnoresUnknownPayload() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let result = try runCodexScript(
        "notch-codex-notify",
        arguments: [#"{"type":"unrelated-event"}"#],
        home: scratch,
        extraEnvironment: ["NOTCH_CODEX_SESSION_ID": "codex-unknown"]
    )

    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("sessions/codex-unknown.json").path))
}

@Test func codexNotifyNeverCreatesSessions() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // A late turn-complete after the shim already removed the session (codex
    // fires notify asynchronously) must not resurrect it as a ghost.
    let payload = #"{"type":"agent-turn-complete"}"#
    let result = try runCodexScript(
        "notch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: ["NOTCH_CODEX_SESSION_ID": "codex-ghost"]
    )

    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("sessions/codex-ghost.json").path))
}

@Test func codexNotifyCreatesDesktopSessionsFromAppTurnEnd() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // Codex Desktop client → creation allowed, keyed like the rollout poller
    let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"019fca6a-be3f-7ee1-a864-fbf884a1692f","cwd":"/tmp/projects/aquarium"}"#
    let result = try runCodexScript("notch-codex-notify", arguments: [payload], home: scratch)

    #expect(result.status == 0)
    let envelope = try codexPayload(id: "codex-app-019fca6a", home: scratch)
    #expect(envelope["status"] as? String == "done")
    #expect(envelope["source"] as? String == "codex-desktop")
    #expect(envelope["project"] as? String == "aquarium")

    // desktop approval requests surface as needs_me on the same entry
    let approval = #"{"type":"exec-approval-request","client":"Codex Desktop","thread-id":"019fca6a-be3f-7ee1-a864-fbf884a1692f","cwd":"/tmp/projects/aquarium"}"#
    _ = try runCodexScript("notch-codex-notify", arguments: [approval], home: scratch)
    let updated = try codexPayload(id: "codex-app-019fca6a", home: scratch)
    #expect(updated["status"] as? String == "needs_me")

    // exec client without an existing session still refuses creation
    let execPayload = #"{"type":"agent-turn-complete","client":"codex_exec","thread-id":"deadbeef-0000-0000-0000-000000000000"}"#
    _ = try runCodexScript("notch-codex-notify", arguments: [execPayload], home: scratch)
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("sessions/codex-deadbeef-0000-0000-0000-000000000000.json").path))
}

@Test func codexNotifyChainsSavedCommandWithPayloadAppended() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let recorder = scratch.appendingPathComponent("record-notify")
    let recordedArguments = scratch.appendingPathComponent("recorded-arguments.json")
    try """
    #!/bin/sh
    jq -n --args '$ARGS.positional' -- "$@" > "$RECORDED_ARGUMENTS"
    """.write(to: recorder, atomically: true, encoding: .utf8)
    try makeExecutable(recorder)

    let chain = [recorder.path, "turn-ended", "argument with spaces"]
    let chainData = try JSONSerialization.data(withJSONObject: chain)
    try chainData.write(to: scratch.appendingPathComponent("codex-notify-chain.json"))

    let payload = #"{"type":"unknown-but-still-chained","value":"payload value"}"#
    let result = try runCodexScript(
        "notch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: ["RECORDED_ARGUMENTS": recordedArguments.path]
    )

    #expect(result.status == 0)
    let data = try Data(contentsOf: recordedArguments)
    let arguments = try #require(JSONSerialization.jsonObject(with: data) as? [String])
    #expect(arguments == ["turn-ended", "argument with spaces", payload])
}

@Test func codexShimEmitsWorkingThenRemovesAndPreservesExitStatus() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let fakeBin = scratch.appendingPathComponent("fake-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let fakeCodex = fakeBin.appendingPathComponent("codex")
    let recordedArguments = scratch.appendingPathComponent("fake-codex-arguments.json")
    try """
    #!/bin/sh
    jq -n --args '$ARGS.positional' -- "$@" > "$FAKE_CODEX_ARGUMENTS"
    sleep 1
    exit 7
    """.write(to: fakeCodex, atomically: true, encoding: .utf8)
    try makeExecutable(fakeCodex)

    let process = Process()
    process.executableURL = codexRepoRoot().appendingPathComponent("scripts/codex-shim")
    process.arguments = ["--model", "gpt-test", "prompt with spaces"]
    var environment = cleanCodexEnvironment(home: scratch)
    environment["PATH"] = "\(codexRepoRoot().appendingPathComponent("scripts").path):\(fakeBin.path):/usr/bin:/bin"
    environment["FAKE_CODEX_ARGUMENTS"] = recordedArguments.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    let sessionID = "codex-\(process.processIdentifier)"
    let sessionURL = scratch.appendingPathComponent("sessions/\(sessionID).json")
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: sessionURL.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }

    let working = try codexPayload(id: sessionID, home: scratch)
    #expect(working["status"] as? String == "working")
    #expect(working["source"] as? String == "codex")
    #expect(working["agent"] as? String == "codex")

    process.waitUntilExit()
    #expect(process.terminationStatus == 7)
    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))

    let argumentData = try Data(contentsOf: recordedArguments)
    let arguments = try #require(JSONSerialization.jsonObject(with: argumentData) as? [String])
    #expect(arguments == ["--model", "gpt-test", "prompt with spaces"])
}

@Test func codexInstallerIsIdempotentAndPreservesExistingNotifyChain() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed-notch-hud", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "export PATH=/usr/bin\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    let skyNotify = #"["/Applications/Codex Computer Use.app/Client", "turn-ended"]"#
    let original = "model = \"gpt-test\"\nnotify = \(skyNotify)\napproval_policy = \"on-request\"\n"
    try original.write(to: config, atomically: true, encoding: .utf8)

    let first = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(first.status == 0)
    #expect(first.output.contains("bin files: changed"))
    #expect(first.output.contains("Codex notify config: changed"))
    #expect(first.output.contains("zsh PATH shim: changed"))

    for filename in ["notch-emit", "notch-codex-notify", "codex"] {
        #expect(FileManager.default.isExecutableFile(atPath: prefix.appendingPathComponent("bin/\(filename)").path))
    }

    let notifyTarget = prefix.appendingPathComponent("bin/notch-codex-notify").path
    let expectedConfig = "model = \"gpt-test\"\nnotify = [\(jsonString(notifyTarget))]\napproval_policy = \"on-request\"\n"
    #expect(try String(contentsOf: config, encoding: .utf8) == expectedConfig)

    let chainData = try Data(contentsOf: prefix.appendingPathComponent("codex-notify-chain.json"))
    let savedChain = try #require(JSONSerialization.jsonObject(with: chainData) as? [String])
    #expect(savedChain == ["/Applications/Codex Computer Use.app/Client", "turn-ended"])

    let backupsAfterFirst = try backupNames(nextTo: config)
    #expect(backupsAfterFirst.count == 1)
    let zshBackupsAfterFirst = try backupNames(nextTo: home.appendingPathComponent(".zshrc"))
    #expect(zshBackupsAfterFirst.count == 1)

    let second = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(second.status == 0)
    #expect(second.output.contains("bin files: skipped"))
    #expect(second.output.contains("Codex notify config: skipped"))
    #expect(second.output.contains("zsh PATH shim: skipped"))
    #expect(try backupNames(nextTo: config) == backupsAfterFirst)
    #expect(try backupNames(nextTo: home.appendingPathComponent(".zshrc")) == zshBackupsAfterFirst)

    let configWithoutNotify = scratch.appendingPathComponent("codex/no-notify.toml")
    let noNotifyOriginal = "model = \"gpt-test\"\napproval_policy = \"never\"\n"
    try noNotifyOriginal.write(to: configWithoutNotify, atomically: true, encoding: .utf8)
    let appendRun = try runInstaller(home: home, prefix: prefix, config: configWithoutNotify)
    #expect(appendRun.status == 0)
    let appended = try String(contentsOf: configWithoutNotify, encoding: .utf8)
    #expect(appended.hasPrefix(noNotifyOriginal))
    #expect(appended.contains("notify = [\(jsonString(notifyTarget))]"))
}

private func codexRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeCodexScratch() throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-codex-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
}

private func cleanCodexEnvironment(home: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["NOTCH_HUD_HOME"] = home.path
    environment["NOTCH_HUD_TTY"] = ""
    environment["TERM_PROGRAM"] = nil
    environment["ITERM_SESSION_ID"] = nil
    environment["WEZTERM_PANE"] = nil
    environment["KITTY_WINDOW_ID"] = nil
    environment["WINDOWID"] = nil
    return environment
}

private func runCodexScript(
    _ name: String,
    arguments: [String],
    home: URL,
    extraEnvironment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [codexRepoRoot().appendingPathComponent("scripts/\(name)").path] + arguments
    var environment = cleanCodexEnvironment(home: home)
    for (key, value) in extraEnvironment {
        environment[key] = value
    }
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

private func runInstaller(home: URL, prefix: URL, config: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [codexRepoRoot().appendingPathComponent("scripts/install-codex-adapter.sh").path]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["NOTCH_HUD_INSTALL_PREFIX"] = prefix.path
    environment["NOTCH_HUD_CODEX_CONFIG"] = config.path
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

private func codexPayload(id: String, home: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent("sessions/\(id).json"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func makeExecutable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
}

private func backupNames(nextTo file: URL) throws -> [String] {
    let prefix = file.lastPathComponent + ".bak."
    return try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        .filter { $0.hasPrefix(prefix) }
        .sorted()
}
