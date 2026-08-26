import Foundation
import Testing
@testable import Vibenotch

@Suite("ClaudeUsageHybrid")
struct ClaudeUsageHybridTests {
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct CountingCredentials: ClaudeCredentialReading {
        let counter: CallCounter
        let token: String

        func accessToken() throws -> String {
            counter.increment()
            return token
        }
    }

    private struct CountingHTTP: UsageHTTPPerforming {
        let counter: CallCounter
        let body: Data

        func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
            counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
    }

    private struct FailIfCalledCredentials: ClaudeCredentialReading {
        func accessToken() throws -> String {
            throw UsageUnavailable.unexpectedResponse("credentials unexpectedly called")
        }
    }

    private struct FailIfCalledHTTP: UsageHTTPPerforming {
        func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
            throw UsageUnavailable.unexpectedResponse("HTTP unexpectedly called")
        }
    }

    private final class RecordingCommandRunner: ClaudeSecurityCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var executableURL: URL?
        private(set) var arguments: [String]?
        let result: ClaudeSecurityCommandOutput

        init(status: Int32 = 0, stdout: Data) {
            result = ClaudeSecurityCommandOutput(
                terminationStatus: status,
                standardOutput: stdout
            )
        }

        func run(executableURL: URL, arguments: [String]) throws -> ClaudeSecurityCommandOutput {
            lock.lock()
            self.executableURL = executableURL
            self.arguments = arguments
            lock.unlock()
            return result
        }

        func invocation() -> (URL?, [String]?) {
            lock.lock()
            defer { lock.unlock() }
            return (executableURL, arguments)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_787_741_000)
    private let fallbackBody = Data("""
    {"five_hour":{"utilization":31,"resets_at":"2026-08-26T23:00:00Z"}}
    """.utf8)

    @Test func validFreshCacheAvoidsCredentialsAndHTTP() async throws {
        try await withCacheURL(inDirectoryNamed: "Vibenotch cache path with spaces") { cacheURL in
            let capturedAt = now.timeIntervalSince1970 - 30
            try write("""
            {"schema_version":1,"captured_at":\(capturedAt),"rate_limits":{
              "five_hour":{"used_percentage":12.5,"resets_at":\(capturedAt + 3600)},
              "seven_day":{"used_percentage":84,"resets_at":\(capturedAt + 604800)}
            }}
            """, to: cacheURL)
            let fetcher = ClaudeUsageFetcher(
                cache: FileClaudeStatusLineCache(cacheURL: cacheURL),
                credentials: FailIfCalledCredentials(),
                http: FailIfCalledHTTP()
            )

            let snapshot = try await fetcher.fetch(now: now)

            #expect(snapshot.capturedAt == Date(timeIntervalSince1970: capturedAt))
            #expect(snapshot.windows.count == 2)
            #expect(snapshot.window(.session)?.percentUsed == 12.5)
            #expect(snapshot.window(.session)?.severity == .normal)
            #expect(snapshot.window(.weekly)?.percentUsed == 84)
            #expect(snapshot.window(.weekly)?.severity == .warning)
        }
    }

    @Test func oneDocumentedWindowIsEnoughForACacheHit() async throws {
        try await withCacheURL(inDirectoryNamed: "one-window") { cacheURL in
            let capturedAt = now.timeIntervalSince1970
            try write("""
            {"schema_version":1,"captured_at":\(capturedAt),"rate_limits":{
              "seven_day":{"used_percentage":50,"resets_at":\(capturedAt + 604800)}
            }}
            """, to: cacheURL)
            let fetcher = ClaudeUsageFetcher(
                cache: FileClaudeStatusLineCache(cacheURL: cacheURL),
                credentials: FailIfCalledCredentials(),
                http: FailIfCalledHTTP()
            )

            let snapshot = try await fetcher.fetch(now: now)

            #expect(snapshot.windows.count == 1)
            #expect(snapshot.window(.session) == nil)
            #expect(snapshot.window(.weekly)?.percentUsed == 50)
        }
    }

    @Test func cacheMissesAndInvalidContentFallBackExactlyOnce() async throws {
        let capturedAt = now.timeIntervalSince1970
        let cases: [(String, String?)] = [
            ("missing", nil),
            ("empty", ""),
            ("malformed", "{not-json"),
            ("stale", "{\"schema_version\":1,\"captured_at\":\(capturedAt - 121),\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\(capturedAt + 1000)}}}"),
            ("future", "{\"schema_version\":1,\"captured_at\":\(capturedAt + 6),\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\(capturedAt + 1000)}}}"),
            ("wrong-schema", "{\"schema_version\":2,\"captured_at\":\(capturedAt),\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\(capturedAt + 1000)}}}"),
            ("no-windows", "{\"schema_version\":1,\"captured_at\":\(capturedAt),\"rate_limits\":{}}"),
            ("present-null-window", "{\"schema_version\":1,\"captured_at\":\(capturedAt),\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\(capturedAt + 1000)},\"seven_day\":null}}"),
            ("invalid-percent", "{\"schema_version\":1,\"captured_at\":\(capturedAt),\"rate_limits\":{\"five_hour\":{\"used_percentage\":101,\"resets_at\":\(capturedAt + 1000)}}}"),
            ("reset-predates-capture", "{\"schema_version\":1,\"captured_at\":\(capturedAt),\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\(capturedAt - 1000)}}}"),
            ("invalid-reset-epoch", "{\"schema_version\":1,\"captured_at\":\(capturedAt),\"rate_limits\":{\"five_hour\":{\"used_percentage\":10,\"resets_at\":\((capturedAt + 1000) * 1000)}}}")
        ]

        for (name, contents) in cases {
            try await withCacheURL(inDirectoryNamed: name) { cacheURL in
                if let contents { try write(contents, to: cacheURL) }
                let credentialCalls = CallCounter()
                let httpCalls = CallCounter()
                let fetcher = ClaudeUsageFetcher(
                    cache: FileClaudeStatusLineCache(cacheURL: cacheURL),
                    credentials: CountingCredentials(counter: credentialCalls, token: "in-memory-token"),
                    http: CountingHTTP(counter: httpCalls, body: fallbackBody)
                )

                let snapshot = try await fetcher.fetch(now: now)

                #expect(snapshot.window(.session)?.percentUsed == 31, "case: \(name)")
                #expect(credentialCalls.read() == 1, "case: \(name)")
                #expect(httpCalls.read() == 1, "case: \(name)")
            }
        }
    }

    @Test func securityFallbackUsesExactNonShellCommandAndParsesOnlyInMemory() throws {
        let token = "sensitive-token-never-log"
        let runner = RecordingCommandRunner(
            stdout: Data("{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}\n".utf8)
        )
        let reader = SecurityToolClaudeCredentialReader(runner: runner)

        #expect(try reader.accessToken() == token)
        let invocation = runner.invocation()
        #expect(invocation.0?.path == "/usr/bin/security")
        #expect(invocation.1 == [
            "find-generic-password", "-s", "Claude Code-credentials", "-w"
        ])
    }

    @Test func securityFallbackRejectsNonzeroAndMalformedOutputWithoutLeakingIt() {
        let secret = "secret-that-must-not-appear"
        let nonzero = SecurityToolClaudeCredentialReader(
            runner: RecordingCommandRunner(status: 44, stdout: Data(secret.utf8))
        )
        #expect(throws: UsageUnavailable.notLoggedIn) {
            try nonzero.accessToken()
        }

        let malformed = SecurityToolClaudeCredentialReader(
            runner: RecordingCommandRunner(stdout: Data(secret.utf8))
        )
        do {
            _ = try malformed.accessToken()
            Issue.record("expected malformed helper output to fail")
        } catch UsageUnavailable.unexpectedResponse(let message) {
            #expect(!message.contains(secret))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    private func withCacheURL(
        inDirectoryNamed name: String,
        body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.appendingPathComponent("claude-usage.json"))
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url)
    }
}
