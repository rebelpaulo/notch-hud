import Foundation
import Testing

@Test func sleepguardOnOffAndStatusUseOverriddenPmset() throws {
    let fixture = try SleepGuardScriptFixture()
    defer { fixture.remove() }

    #expect(try fixture.run("on") == 0)
    #expect(try fixture.run("off") == 0)
    fixture.statusValue = 1
    #expect(try fixture.run("status") == 0)
    fixture.statusValue = 0
    #expect(try fixture.run("status") != 0)

    let calls = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(calls.contains("-a disablesleep 1"))
    #expect(calls.contains("-a disablesleep 0"))
    #expect(calls.components(separatedBy: "-g").count - 1 == 2)
}

@Test func watchdogTurnsSleepOffOnlyWhenAppIsAbsent() throws {
    let fixture = try SleepGuardScriptFixture()
    defer { fixture.remove() }
    fixture.statusValue = 1

    fixture.appIsRunning = false
    #expect(try fixture.runWatchdog() == 0)
    var calls = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(calls.contains("-g\n-a disablesleep 0"))

    try Data().write(to: fixture.logURL)
    fixture.appIsRunning = true
    #expect(try fixture.runWatchdog() == 0)
    calls = try String(contentsOf: fixture.logURL, encoding: .utf8)
    #expect(calls == "-g\n")
}

private final class SleepGuardScriptFixture {
    let scratch: URL
    let logURL: URL
    private let root: URL
    private let fakePmset: URL
    private let fakePgrep: URL
    var statusValue = 0
    var appIsRunning = false

    init() throws {
        root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepguard-tests-\(UUID().uuidString)", isDirectory: true)
        logURL = scratch.appendingPathComponent("pmset.log")
        fakePmset = scratch.appendingPathComponent("fake-pmset")
        fakePgrep = scratch.appendingPathComponent("fake-pgrep")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data().write(to: logURL)
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_PMSET_LOG"
            if [ "${1:-}" = -g ]; then
                printf ' SleepDisabled %s\\n' "$FAKE_SLEEP_DISABLED"
            fi
            """,
            to: fakePmset
        )
        try writeExecutable(
            """
            #!/bin/sh
            [ "$FAKE_APP_RUNNING" = 1 ]
            """,
            to: fakePgrep
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func run(_ action: String) throws -> Int32 {
        try runProcess(
            root.appendingPathComponent("scripts/notch-sleepguard"),
            arguments: [action]
        )
    }

    func runWatchdog() throws -> Int32 {
        try runProcess(root.appendingPathComponent("scripts/notch-sleepguard-watchdog"))
    }

    private func runProcess(_ executable: URL, arguments: [String] = []) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [executable.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NOTCH_SLEEPGUARD_PMSET"] = fakePmset.path
        environment["NOTCH_SLEEPGUARD_PGREP"] = fakePgrep.path
        environment["FAKE_PMSET_LOG"] = logURL.path
        environment["FAKE_SLEEP_DISABLED"] = String(statusValue)
        environment["FAKE_APP_RUNNING"] = appIsRunning ? "1" : "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try contents.data(using: .utf8)!.write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: url.path
    )
}
