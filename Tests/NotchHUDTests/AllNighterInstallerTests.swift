import Foundation
import Testing

@Test func allNighterInstallerIsValidatedExactAndIdempotent() throws {
    let fixture = try AllNighterInstallerFixture()
    defer { fixture.remove() }

    let first = try fixture.run()
    #expect(first.status == 0)
    #expect(first.output.contains("sudoers: changed"))
    #expect(first.output.contains("LaunchAgent plist: changed"))

    let expectedSudoers = """
    # Installed by NotchHUD All-Nighter.
    testuser ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0

    """
    #expect(try String(contentsOf: fixture.sudoersURL, encoding: .utf8) == expectedSudoers)
    let plist = try String(contentsOf: fixture.plistURL, encoding: .utf8)
    #expect(plist.contains("<key>StartInterval</key><integer>60</integer>"))
    #expect(plist.contains(fixture.prefix.appendingPathComponent("bin/notch-sleepguard-watchdog").path))

    let second = try fixture.run()
    #expect(second.status == 0)
    #expect(second.output.contains("sudoers: skipped"))
    #expect(second.output.contains("notch-sleepguard: skipped"))
    #expect(second.output.contains("watchdog: skipped"))
    #expect(second.output.contains("LaunchAgent plist: skipped"))

    let validations = try String(contentsOf: fixture.visudoLogURL, encoding: .utf8)
        .split(separator: "\n")
    #expect(validations.count == 2)
    #expect(validations.allSatisfy { $0.contains("-c -f") })
}

@Test func allNighterInstallerAbortsBeforeInstallingInvalidSudoers() throws {
    let fixture = try AllNighterInstallerFixture()
    defer { fixture.remove() }
    fixture.visudoShouldFail = true

    let result = try fixture.run()
    #expect(result.status != 0)
    #expect(FileManager.default.fileExists(atPath: fixture.sudoersURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("bin/notch-sleepguard").path) == false)
}

private final class AllNighterInstallerFixture {
    let scratch: URL
    let prefix: URL
    let sudoersURL: URL
    let plistURL: URL
    let visudoLogURL: URL
    private let root: URL
    private let fakeBin: URL
    private let launchagents: URL
    private let sudoersDirectory: URL
    var visudoShouldFail = false

    init() throws {
        root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("all-nighter-installer-\(UUID().uuidString)", isDirectory: true)
        prefix = scratch.appendingPathComponent("prefix", isDirectory: true)
        sudoersDirectory = scratch.appendingPathComponent("sudoers", isDirectory: true)
        launchagents = scratch.appendingPathComponent("LaunchAgents", isDirectory: true)
        fakeBin = scratch.appendingPathComponent("fake-bin", isDirectory: true)
        sudoersURL = sudoersDirectory.appendingPathComponent("notch-hud")
        plistURL = launchagents.appendingPathComponent("com.actionable.notchhud.sleepguard.plist")
        visudoLogURL = scratch.appendingPathComponent("visudo.log")
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try Data().write(to: visudoLogURL)
        try writeInstallerExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$FAKE_VISUDO_LOG"
            [ "$FAKE_VISUDO_FAIL" != 1 ]
            """,
            to: fakeBin.appendingPathComponent("visudo")
        )
        try writeInstallerExecutable(
            "#!/bin/sh\nexit 0\n",
            to: fakeBin.appendingPathComponent("launchctl")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func run() throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("scripts/install-all-nighter.sh").path]
        var environment = ProcessInfo.processInfo.environment
        environment["NOTCH_AN_EUID"] = "0"
        environment["NOTCH_AN_PREFIX"] = prefix.path
        environment["NOTCH_AN_SUDOERS_DIR"] = sudoersDirectory.path
        environment["NOTCH_AN_LAUNCHAGENTS_DIR"] = launchagents.path
        environment["NOTCH_AN_LAUNCHCTL"] = fakeBin.appendingPathComponent("launchctl").path
        environment["SUDO_USER"] = "testuser"
        environment["SUDO_UID"] = "501"
        environment["FAKE_VISUDO_LOG"] = visudoLogURL.path
        environment["FAKE_VISUDO_FAIL"] = visudoShouldFail ? "1" : "0"
        environment["PATH"] = "\(fakeBin.path):/usr/bin:/bin"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private func writeInstallerExecutable(_ contents: String, to url: URL) throws {
    try contents.data(using: .utf8)!.write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o755)],
        ofItemAtPath: url.path
    )
}
