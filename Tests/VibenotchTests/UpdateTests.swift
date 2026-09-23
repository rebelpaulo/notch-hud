import Foundation
import Testing
@testable import Vibenotch

@Test func appVersionParsesAndComparesSemanticReleaseTags() throws {
    #expect(AppVersion("v0.4.0") == AppVersion(major: 0, minor: 4, patch: 0))
    #expect(AppVersion("0.4.1")! > AppVersion("0.4.0")!)
    #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
    #expect(AppVersion("v0.4") == nil)
    #expect(AppVersion("v0.4.0-beta") == nil)
    #expect(AppVersion("v0.4.0; touch /tmp/nope") == nil)
}

@MainActor
@Test func updateStoreShowsOnlyANewerOfficialGitHubRelease() async throws {
    let newer = UpdateStore(
        currentVersion: AppVersion(major: 0, minor: 4, patch: 0),
        checker: FakeReleaseChecker(tag: "v0.5.0")
    )
    newer.refresh()
    while newer.isChecking { await Task.yield() }

    #expect(newer.availableUpdate?.tagName == "v0.5.0")
    #expect(newer.availableUpdate?.version == AppVersion("0.5.0"))

    let same = UpdateStore(
        currentVersion: AppVersion(major: 0, minor: 5, patch: 0),
        checker: FakeReleaseChecker(tag: "v0.5.0")
    )
    same.refresh()
    while same.isChecking { await Task.yield() }

    #expect(same.availableUpdate == nil)
}

@MainActor
@Test func updateStoreRejectsAReleaseOutsideTheExpectedGitHubHost() async throws {
    let store = UpdateStore(
        currentVersion: AppVersion(major: 0, minor: 4, patch: 0),
        checker: FakeReleaseChecker(
            tag: "v0.5.0",
            releaseURL: URL(string: "https://example.com/releases/v0.5.0")!
        )
    )
    store.refresh()
    while store.isChecking { await Task.yield() }

    #expect(store.availableUpdate == nil)
}

@Test func githubReleaseCheckerUsesThePinnedEndpointAndHeaders() async throws {
    let http = RecordingUpdateHTTP()
    let checker = GitHubLatestReleaseChecker(http: http)

    let release = try await checker.latestRelease()
    let request = try #require(await http.lastRequest)

    #expect(release.tagName == "v0.5.0")
    #expect(request.url == GitHubLatestReleaseChecker.endpoint)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Vibenotch update checker")
}

@MainActor
@Test func terminalUpdaterCommandContainsOnlyTheFixedHelperAndValidatedTag() throws {
    let helper = URL(fileURLWithPath: "/Users/test user/.vibenotch/bin/vibenotch-update")

    let command = try TerminalUpdateLauncher.command(updaterURL: helper, tagName: "v0.5.0")

    #expect(command == "/bin/sh '/Users/test user/.vibenotch/bin/vibenotch-update' 'v0.5.0'")
    #expect(throws: UpdateLaunchError.self) {
        try TerminalUpdateLauncher.command(
            updaterURL: helper,
            tagName: "v0.5.0; open -a Calculator"
        )
    }
}

@Test func updateScriptRejectsAnythingExceptASemanticReleaseTag() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibenotch-update-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let marker = scratch.appendingPathComponent("must-not-exist")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        root.appendingPathComponent("scripts/vibenotch-update").path,
        "v0.5.0; touch \(marker.path)",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    #expect(process.terminationStatus == 64)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func updateScriptStopsBeforeDownloadWhenTargetIsAlreadyInstalled() throws {
    let result = try runUpdaterVersionPreflight(
        installedVersion: "1.0.2",
        targetTag: "v1.0.2"
    )

    #expect(result.status == 0)
    #expect(result.output.contains("Checking installed Vibenotch version"))
    #expect(result.output.contains("Vibenotch 1.0.2 is already installed. Nothing to do."))
    #expect(!result.output.contains("Downloading Vibenotch"))
}

@Test func updateScriptRefusesToDowngradeANewerInstalledVersion() throws {
    let result = try runUpdaterVersionPreflight(
        installedVersion: "1.10.0",
        targetTag: "v1.9.99"
    )

    #expect(result.status == 0)
    #expect(result.output.contains("Vibenotch 1.10.0 is newer than 1.9.99. Nothing to do."))
    #expect(!result.output.contains("Downloading Vibenotch"))
}

@Test func packagedAppAndRuntimeAgreeOnTheSwiftPMResourceBundlePath() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(
        contentsOf: root.appendingPathComponent("scripts/make-app.sh"),
        encoding: .utf8
    )

    #expect(script.contains(
        #"cp -R .build/release/Vibenotch_Vibenotch.bundle "$APP/Contents/Resources/""#
    ))

    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vibenotch packaged resources-\(UUID().uuidString)")
    let app = scratch.appendingPathComponent("Vibenotch.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    let resourceBundle = resources.appendingPathComponent("Vibenotch_Vibenotch.bundle")
    try FileManager.default.createDirectory(at: resourceBundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    try writeBundlePlist(
        identifier: "com.rebelpaulo.vibenotch.fixture",
        to: app.appendingPathComponent("Contents/Info.plist")
    )
    try writeBundlePlist(
        identifier: "com.rebelpaulo.vibenotch.fixture.resources",
        to: resourceBundle.appendingPathComponent("Info.plist")
    )

    let packagedApp = try #require(Bundle(url: app))
    let resolved = try #require(VibenotchResources.packagedBundle(in: packagedApp))
    #expect(resolved.bundleURL.standardizedFileURL == resourceBundle.standardizedFileURL)
}

@Test func updateScriptVerifiesTheSignedArtifactBeforeExtraction() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(
        contentsOf: root.appendingPathComponent("scripts/vibenotch-update"),
        encoding: .utf8
    )
    let trustedKey = try String(
        contentsOf: root.appendingPathComponent("scripts/release-signing-public.pem"),
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    let signatureCheck = try #require(script.range(of: "openssl dgst -sha256 -verify"))
    let checksumCheck = try #require(script.range(of: "actual_hash=$(/usr/bin/shasum -a 256"))
    let extraction = try #require(script.range(of: "/usr/bin/tar -xzf"))
    let versionCheck = try #require(script.range(of: "Checking installed Vibenotch version"))
    let download = try #require(script.range(of: "Downloading Vibenotch"))

    #expect(versionCheck.lowerBound < download.lowerBound)
    #expect(signatureCheck.lowerBound < checksumCheck.lowerBound)
    #expect(checksumCheck.lowerBound < extraction.lowerBound)
    #expect(script.contains("releases/download/$tag"))
    #expect(script.contains(trustedKey))
}

@Test func updateAndReleaseScriptsHaveValidShellSyntax() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    for name in ["vibenotch-update", "package-release.sh"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", root.appendingPathComponent("scripts/\(name)").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

@Test func installerRestartsOnlyAfterEveryInstallStepCompletes() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = try String(
        contentsOf: root.appendingPathComponent("scripts/install.sh"),
        encoding: .utf8
    )
    let main = try #require(script.range(of: "# --- main"))
    let mainScript = script[main.lowerBound...]

    let bundleInstall = try #require(mainScript.range(of: "\ninstall_app_bundle\n"))
    let runtimeInstall = try #require(mainScript.range(of: "\ninstall_runtime_scripts\n"))
    let claudeInstall = try #require(mainScript.range(of: "\ninstall_claude_hooks_step\n"))
    let codexInstall = try #require(mainScript.range(of: "\ninstall_codex_step\n"))
    let restart = try #require(mainScript.range(of: "\nrestart_app\n"))

    #expect(bundleInstall.lowerBound < runtimeInstall.lowerBound)
    #expect(runtimeInstall.lowerBound < claudeInstall.lowerBound)
    #expect(claudeInstall.lowerBound < codexInstall.lowerBound)
    #expect(codexInstall.lowerBound < restart.lowerBound)
    #expect(script.contains("osascript_command\""))
    #expect(script.contains("app_binary=$app_target/Contents/MacOS/Vibenotch"))
    #expect(script.contains("pkill_command\" -f -x \"$app_binary"))
    #expect(script.contains("pgrep_command\" -f -x \"$app_binary"))
    #expect(script.contains("case $pgrep_status in"))
    #expect(script.contains("could not wait for the previous app to stop"))
}

private struct FakeReleaseChecker: LatestReleaseChecking {
    let tag: String
    let releaseURL: URL

    init(
        tag: String,
        releaseURL: URL = URL(string: "https://github.com/rebelpaulo/notch-hud/releases/tag/v0.5.0")!
    ) {
        self.tag = tag
        self.releaseURL = releaseURL
    }

    func latestRelease() async throws -> GitHubRelease {
        GitHubRelease(tagName: tag, releaseURL: releaseURL)
    }
}

private actor RecordingUpdateHTTP: UpdateHTTPPerforming {
    private(set) var lastRequest: URLRequest?

    func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let data = Data(
            #"{"tag_name":"v0.5.0","html_url":"https://github.com/rebelpaulo/notch-hud/releases/tag/v0.5.0"}"#.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

private func runUpdaterVersionPreflight(
    installedVersion: String,
    targetTag: String
) throws -> (status: Int32, output: String) {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vibenotch updater path with spaces-\(UUID().uuidString)")
    let plist = scratch.appendingPathComponent("Vibenotch.app/Contents/Info.plist")
    try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: scratch) }

    let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": installedVersion],
        format: .xml,
        options: 0
    )
    try data.write(to: plist)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        root.appendingPathComponent("scripts/vibenotch-update").path,
        targetTag,
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["VIBENOTCH_UPDATE_INFO_PLIST"] = plist.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: outputData, as: UTF8.self))
}

private func writeBundlePlist(identifier: String, to url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Vibenotch fixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ],
        format: .xml,
        options: 0
    )
    try data.write(to: url)
}
