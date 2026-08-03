import Foundation
import Testing

@Test func ttylessClaudeEmitterClassifiesDesktopAndExplicitSourceWins() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scratch = root
        .appendingPathComponent(".foreman/scratch/emitter-test", isDirectory: true)
        .appendingPathComponent("unit-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("scripts/notch-emit").path

    try runEmitter(script, home: scratch, arguments: ["ttyless", "claude-code", "working"])
    let ttyless = try payload(id: "ttyless", home: scratch)
    #expect(ttyless["source"] as? String == "claude-desktop")

    try runEmitter(
        script,
        home: scratch,
        arguments: ["explicit", "claude-code", "working", "--source", "codex"]
    )
    let explicit = try payload(id: "explicit", home: scratch)
    #expect(explicit["source"] as? String == "codex")
}

private func runEmitter(_ script: String, home: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script] + arguments

    var environment = ProcessInfo.processInfo.environment
    environment["NOTCH_HUD_HOME"] = home.path
    environment["TERM_PROGRAM"] = nil
    environment["ITERM_SESSION_ID"] = nil
    environment["WEZTERM_PANE"] = nil
    environment["KITTY_WINDOW_ID"] = nil
    environment["WINDOWID"] = nil
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func payload(id: String, home: URL) throws -> [String: Any] {
    let url = home.appendingPathComponent("sessions/\(id).json")
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
