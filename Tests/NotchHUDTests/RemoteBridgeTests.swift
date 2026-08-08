import Foundation
import Testing
@testable import NotchHUD

@MainActor
@Test func remoteBridgeTracksBatteryThresholdsAndResetsTheDischargeCycle() async throws {
    let fixture = try RemoteBridgeFixture(percent: 60, onAC: false)
    defer { fixture.remove() }

    await fixture.bridge.checkNow()
    fixture.power.percent = 49
    await fixture.bridge.checkNow()
    await fixture.bridge.checkNow()
    fixture.power.percent = 19
    await fixture.bridge.checkNow()

    var calls = await fixture.runner.recordedCalls()
    #expect(calls.map(\.dropTag) == [
        ["NotchHUD", "Bateria a 50% — All-Nighter ativo"],
        ["NotchHUD", "Bateria a 30% — All-Nighter ativo"],
        ["NotchHUD", "Bateria a 20% — All-Nighter ativo"]
    ])

    fixture.power.isOnACPower = true
    await fixture.bridge.checkNow()
    fixture.power.isOnACPower = false
    fixture.power.percent = 60
    await fixture.bridge.checkNow()
    fixture.power.percent = 50
    await fixture.bridge.checkNow()

    calls = await fixture.runner.recordedCalls()
    #expect(calls.last?.dropTag == ["NotchHUD", "Bateria a 50% — All-Nighter ativo"])
}

@MainActor
@Test func remoteBridgeDeduplicatesNeedsMeUntilTheSessionLeaves() async throws {
    let fixture = try RemoteBridgeFixture()
    defer { fixture.remove() }

    fixture.store.sessions = [remoteSession(id: "s1", project: "Álbum", status: .needs_me)]
    await fixture.bridge.checkNow()
    await fixture.bridge.checkNow()
    fixture.store.sessions = [remoteSession(id: "s1", project: "Álbum", status: .working)]
    await fixture.bridge.checkNow()
    fixture.store.sessions = [remoteSession(id: "s1", project: "Álbum", status: .needs_me)]
    await fixture.bridge.checkNow()

    let calls = await fixture.runner.recordedCalls()
    #expect(calls.map(\.dropTag) == [
        ["NotchHUD", "Precisa de ti: Álbum"],
        ["NotchHUD", "Precisa de ti: Álbum"]
    ])
}

@MainActor
@Test func remoteBridgeReportsOnlyTheAgentsWorkGraceOffTransition() async throws {
    let fixture = try RemoteBridgeFixture(mode: .whileAgentsWork)
    defer { fixture.remove() }
    await fixture.bridge.checkNow()

    fixture.engine.mode = .off
    fixture.engine.lastOffReason = .whileAgentsWorkGrace
    await fixture.bridge.checkNow()
    await fixture.bridge.checkNow()

    let calls = await fixture.runner.recordedCalls()
    #expect(calls.map(\.dropTag) == [[
        "NotchHUD", "Todos os agentes terminaram — All-Nighter desligou-se"
    ]])
}

@MainActor
@Test func remoteBridgeObeysRemoteOffAndConfirms() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: #"{"keep_awake_enabled":false}"#)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == .off)
    #expect(await fixture.runner.recordedCalls() == [
        ["--state"],
        ["NotchHUD", "All-Nighter desligado remotamente ✓", "remote-off"],
        ["--settings-get"]
    ])
}

@MainActor
@Test func remoteBridgeTurnsAllNighterOnFromThePhone() async throws {
    // The whole point of the bidirectional contract: engine off + remote true
    // must START a session using the configured default mode.
    let fixture = try RemoteBridgeFixture(
        mode: .off,
        stateOutput: #"{"keep_awake_enabled":true}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == fixture.engine.config.defaultMode)
    #expect(await fixture.runner.recordedCalls().contains(
        ["NotchHUD", "All-Nighter ligado remotamente ✓", "remote-on"]
    ))
}

@MainActor
@Test func remoteBridgePublishesLocalToggleSoThePhoneShowsTheTruth() async throws {
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        stateOutput: #"{"keep_awake_enabled":true}"#
    )
    defer { fixture.remove() }

    // First reconcile agrees: both sides on.
    await fixture.bridge.checkNow(pollRemoteState: true)

    // Toggled off ON THE MAC: local truth wins and is pushed up, and the
    // stale remote "true" must NOT switch it back on.
    fixture.engine.mode = .off
    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.lastStatePutBody())
    #expect(body.contains("\"keep_awake_enabled\":false"))
    #expect(fixture.engine.mode == .off)
}

@MainActor
@Test func remoteBridgeSyncsStateAndSettingsWhileInactiveWithoutPushing() async throws {
    let fixture = try RemoteBridgeFixture(
        mode: .off,
        percent: 10,
        onAC: false,
        stateOutput: #"{"keep_awake_enabled":false}"#
    )
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "Quiet", status: .needs_me)]

    await fixture.bridge.checkNow(pollRemoteState: true)

    // No battery/needs-me pushes while off, but state and settings reconcile
    // so the phone can both configure and start the next session.
    let calls = await fixture.runner.recordedCalls()
    #expect(calls == [["--state"], ["--settings-get"]])
}

@MainActor
@Test func remoteBridgeAppliesConfigWhenRemoteRevIsHigher() async throws {
    let fixture = try RemoteBridgeFixture(
        settingsGetOutput: #"{"settings":{"defaultMode":"whileAppsRunning","allowDisplaySleep":false,"batteryFloorPercent":30},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.defaultMode == .whileAppsRunning)
    #expect(!fixture.engine.config.allowDisplaySleep)
    #expect(fixture.engine.config.batteryFloorPercent == 30)
    #expect(await fixture.runner.recordedCalls().last == ["--settings-get"])
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)
}

@MainActor
@Test func remoteBridgeSameRevIsANoOp() async throws {
    let fixture = try RemoteBridgeFixture(
        settingsGetOutput: #"{"settings":{"batteryFloorPercent":30},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(fixture.engine.config.batteryFloorPercent == 30)

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.batteryFloorPercent == 30)
    #expect(await fixture.runner.recordedCalls().filter { $0 == ["--settings-put"] }.isEmpty)
}

@MainActor
@Test func remoteBridgePushesLocalConfigChangeUp() async throws {
    let fixture = try RemoteBridgeFixture()
    defer { fixture.remove() }

    // Baseline poll: remote rev (0) matches lastAppliedSettingsRev (0),
    // local config hasn't moved from the fixture's initial snapshot yet.
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)

    fixture.engine.config.allowDisplaySleep = false
    fixture.engine.config.batteryFloorPercent = 35

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.lastSettingsPutBody())
    let pushed = try #require(
        JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    )
    let settings = try #require(pushed["settings"] as? [String: Any])
    #expect(settings["allowDisplaySleep"] as? Bool == false)
    #expect(settings["batteryFloorPercent"] as? Int == 35)
}

@MainActor
@Test func remoteBridgeIgnoresMalformedRemoteSettingsWithoutCrashing() async throws {
    let fixture = try RemoteBridgeFixture(settingsGetOutput: "not json")
    defer { fixture.remove() }
    let before = fixture.engine.config

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config == before)
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)
}

@MainActor
@Test func remoteBridgeIgnoresUnknownDefaultModeStringWithoutCrashing() async throws {
    let fixture = try RemoteBridgeFixture(
        settingsGetOutput: #"{"settings":{"defaultMode":"bogus","allowDisplaySleep":false},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.defaultMode == .whileAgentsWork)
    #expect(!fixture.engine.config.allowDisplaySleep)
}

@MainActor
private final class RemoteBridgeFixture {
    let scratch: URL
    let engine: FakeRemoteEngine
    let store = FakeRemoteStore()
    let runner: FakeRemoteCommandRunner
    let power: FakeRemotePowerSource
    let bridge: RemoteBridge

    private let suiteName: String
    private let userDefaults: UserDefaults

    init(
        mode: KeepAwakeMode = .manual,
        percent: Int? = 100,
        onAC: Bool = true,
        stateOutput: String = #"{"keep_awake_enabled":true}"#,
        settingsGetOutput: String = #"{"settings":{},"settings_rev":0}"#,
        config: KeepAwakeConfig = KeepAwakeConfig()
    ) throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = scratch.appendingPathComponent(".notch-hud", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try #"{"url":"https://remote.example","secret":"test-secret"}"#.write(
            to: configDirectory.appendingPathComponent("remote.json"),
            atomically: true,
            encoding: .utf8
        )

        engine = FakeRemoteEngine(mode: mode, isOnACPower: onAC, config: config)
        runner = FakeRemoteCommandRunner(stateOutput: stateOutput, settingsGetOutput: settingsGetOutput)
        power = FakeRemotePowerSource(percent: percent, isOnACPower: onAC)
        suiteName = "RemoteBridgeTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: store,
            commandRunner: runner,
            powerSourceProvider: power,
            homeURL: scratch,
            userDefaults: userDefaults
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
        userDefaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class FakeRemoteEngine: RemoteKeepAwakeEngine {
    var mode: KeepAwakeMode
    var isOnACPower: Bool
    var lastOffReason: KeepAwakeOffReason?
    var config: KeepAwakeConfig
    var isActive: Bool { mode != .off }

    init(mode: KeepAwakeMode, isOnACPower: Bool, config: KeepAwakeConfig = KeepAwakeConfig()) {
        self.mode = mode
        self.isOnACPower = isOnACPower
        self.config = config
    }

    func setMode(_ newMode: KeepAwakeMode, now: Date) {
        mode = newMode
        lastOffReason = nil
    }
}

@MainActor
private final class FakeRemoteStore: RemoteSessionStoring {
    var sessions: [Session] = []
}

private final class FakeRemotePowerSource: PowerSourceProviding, @unchecked Sendable {
    var percent: Int?
    var isOnACPower: Bool

    init(percent: Int?, isOnACPower: Bool) {
        self.percent = percent
        self.isOnACPower = isOnACPower
    }
}

private actor FakeRemoteCommandRunner: CommandRunning {
    private var calls: [[String]] = []
    private var stdins: [String?] = []
    private let stateOutput: String
    private let settingsGetOutput: String
    private var ackFailuresRemaining = 0
    private var settingsPutExitCode: Int32 = 0

    init(stateOutput: String, settingsGetOutput: String = #"{"settings":{},"settings_rev":0}"#) {
        self.stateOutput = stateOutput
        self.settingsGetOutput = settingsGetOutput
    }

    func setAckFailures(_ count: Int) {
        ackFailuresRemaining = count
    }

    func setSettingsPutExitCode(_ code: Int32) {
        settingsPutExitCode = code
    }

    func run(arguments: [String], stdin: String?) async -> CommandRunResult {
        calls.append(arguments)
        stdins.append(stdin)
        if arguments == ["--ack-off"], ackFailuresRemaining > 0 {
            ackFailuresRemaining -= 1
            return CommandRunResult(stdout: "", exitCode: 22)
        }
        if arguments == ["--settings-put"] {
            return CommandRunResult(stdout: "", exitCode: settingsPutExitCode)
        }
        let stdout: String
        switch arguments {
        case ["--state"]: stdout = stateOutput
        case ["--settings-get"]: stdout = settingsGetOutput
        default: stdout = "{}"
        }
        return CommandRunResult(stdout: stdout, exitCode: 0)
    }

    func recordedCalls() -> [[String]] {
        calls
    }

    func lastSettingsPutBody() -> String? {
        guard let index = calls.lastIndex(of: ["--settings-put"]) else { return nil }
        return stdins[index]
    }

    func lastStatePutBody() -> String? {
        guard let index = calls.lastIndex(of: ["--state-put"]) else { return nil }
        return stdins[index]
    }
}

private extension Array where Element == String {
    var dropTag: [String] {
        Array(prefix(2))
    }
}

private func remoteSession(id: String, project: String, status: SessionStatus) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: id,
            agent: "codex",
            project: project,
            status: status,
            updated: "2026-08-06T12:00:00Z",
            seq: 1
        ),
        updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}
