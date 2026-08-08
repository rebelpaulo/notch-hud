import Foundation
import Testing

@Test func remotePushBuildsNotifyRequestWithURLAuthAndJSON() throws {
    let fixture = try RemotePushScriptFixture(configured: true)
    defer { fixture.remove() }

    let result = try fixture.run("Aviso", "Corpo com espaços", "tag-1")

    #expect(result.status == 0)
    let arguments = try fixture.arguments()
    #expect(arguments.contains("https://remote.example/api/notify"))
    #expect(arguments.contains("Authorization: Bearer test-secret"))
    #expect(arguments.contains("Content-Type: application/json"))
    let payload = try #require(arguments.element(after: "--data"))
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: String]
    )
    #expect(json == ["title": "Aviso", "body": "Corpo com espaços", "tag": "tag-1"])
}

@Test func remotePushMissingPairingFileExitsZeroSilently() throws {
    let fixture = try RemotePushScriptFixture(configured: false)
    defer { fixture.remove() }

    let result = try fixture.run("Aviso", "Corpo")

    #expect(result.status == 0)
    #expect(result.output.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.logURL.path))
}

@Test func remotePushStatePassesResponseThrough() throws {
    let fixture = try RemotePushScriptFixture(configured: true)
    defer { fixture.remove() }
    fixture.response = #"{"keep_awake_enabled":false}"#

    let result = try fixture.run("--state")

    #expect(result.status == 0)
    #expect(result.output == #"{"keep_awake_enabled":false}"#)
    let arguments = try fixture.arguments()
    #expect(arguments.contains("https://remote.example/api/state"))
    #expect(!arguments.contains("POST"))
}

@Test func remotePushStatePutPublishesTheMacState() throws {
    let fixture = try RemotePushScriptFixture(configured: true)
    defer { fixture.remove() }

    #expect(try fixture.run("--state-put", stdin: #"{"keep_awake_enabled":false}"#).status == 0)

    let arguments = try fixture.arguments()
    #expect(arguments.contains("POST"))
    #expect(arguments.contains("https://remote.example/api/state"))
    #expect(arguments.contains("--data-binary"))
}

@Test func remotePushSettingsGetPassesResponseThrough() throws {
    let fixture = try RemotePushScriptFixture(configured: true)
    defer { fixture.remove() }
    fixture.response = #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":30},"settings_rev":4}"#

    let result = try fixture.run("--settings-get")

    #expect(result.status == 0)
    #expect(result.output == fixture.response)
    let arguments = try fixture.arguments()
    #expect(arguments.contains("https://remote.example/api/state"))
    #expect(!arguments.contains("POST"))
}

@Test func remotePushSettingsPutPostsStdinBodyToSettingsEndpoint() throws {
    let fixture = try RemotePushScriptFixture(configured: true)
    defer { fixture.remove() }
    let body = #"{"settings":{"batteryFloorPercent":30},"base_rev":2}"#

    let result = try fixture.run("--settings-put", stdin: body)

    #expect(result.status == 0)
    let arguments = try fixture.arguments()
    #expect(arguments.contains("POST"))
    #expect(arguments.contains("https://remote.example/api/settings"))
    #expect(arguments.contains("Content-Type: application/json"))
    #expect(arguments.contains("--data-binary"))
    #expect(try fixture.stdinReceivedByCurl() == body)
}

@Test func remotePushSettingsGetAndPutMissingPairingFileExitZeroSilently() throws {
    let fixture = try RemotePushScriptFixture(configured: false)
    defer { fixture.remove() }

    let getResult = try fixture.run("--settings-get")
    #expect(getResult.status == 0)
    #expect(getResult.output.isEmpty)

    let putResult = try fixture.run("--settings-put", stdin: "{}")
    #expect(putResult.status == 0)
    #expect(putResult.output.isEmpty)
}

private final class RemotePushScriptFixture {
    let scratch: URL
    let logURL: URL
    let stdinLogURL: URL
    private let fakeCurl: URL
    private let script: URL
    var response = "{}"

    init(configured: Bool) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        script = root.appendingPathComponent("scripts/notch-remote-push")
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-push-tests-\(UUID().uuidString)", isDirectory: true)
        logURL = scratch.appendingPathComponent("curl-arguments.json")
        stdinLogURL = scratch.appendingPathComponent("curl-stdin.txt")
        fakeCurl = scratch.appendingPathComponent("fake-curl")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        if configured {
            let directory = scratch.appendingPathComponent(".notch-hud", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = #"{"url":"https://remote.example/","secret":"test-secret"}"#
            try config.write(
                to: directory.appendingPathComponent("remote.json"),
                atomically: true,
                encoding: .utf8
            )
        }

        try """
        #!/bin/sh
        jq -cn --args '$ARGS.positional' -- "$@" > "$FAKE_CURL_LOG"
        cat > "$FAKE_CURL_STDIN_LOG"
        printf '%s' "$FAKE_CURL_RESPONSE"
        """.write(to: fakeCurl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: fakeCurl.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func run(_ arguments: String..., stdin: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = scratch.path
        environment["NOTCH_REMOTE_CURL"] = fakeCurl.path
        environment["FAKE_CURL_LOG"] = logURL.path
        environment["FAKE_CURL_STDIN_LOG"] = stdinLogURL.path
        environment["FAKE_CURL_RESPONSE"] = response
        process.environment = environment
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func arguments() throws -> [String] {
        let data = try Data(contentsOf: logURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String])
    }

    func stdinReceivedByCurl() throws -> String {
        String(decoding: try Data(contentsOf: stdinLogURL), as: UTF8.self)
    }
}

private extension Array where Element == String {
    func element(after value: String) -> String? {
        guard let index = firstIndex(of: value), index < self.index(before: endIndex) else {
            return nil
        }
        return self[self.index(after: index)]
    }
}
