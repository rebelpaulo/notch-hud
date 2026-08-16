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
