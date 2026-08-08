import Foundation
import Testing
@testable import Vibenotch

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
        ["Vibenotch", "Battery at 50% — Gotta go! is on"],
        ["Vibenotch", "Battery at 30% — Gotta go! is on"],
        ["Vibenotch", "Battery at 20% — Gotta go! is on"]
    ])

    fixture.power.isOnACPower = true
    await fixture.bridge.checkNow()
    fixture.power.isOnACPower = false
    fixture.power.percent = 60
    await fixture.bridge.checkNow()
    fixture.power.percent = 50
    await fixture.bridge.checkNow()

    calls = await fixture.runner.recordedCalls()
    #expect(calls.last?.dropTag == ["Vibenotch", "Battery at 50% — Gotta go! is on"])
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
        ["Vibenotch", "Needs you: Álbum"],
        ["Vibenotch", "Needs you: Álbum"]
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
        "Vibenotch", "All agents finished — Gotta go! turned itself off"
    ]])
}

@MainActor
@Test func remoteBridgeObeysRemoteOffAndConfirms() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0}"#)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == .off)
    #expect(await fixture.runner.recordedCalls() == [
        ["--state"],
        ["Vibenotch", "Gotta go! turned off remotely ✓", "remote-off"]
    ])
}

@MainActor
@Test func remoteBridgeTurnsAllNighterOnFromThePhone() async throws {
    // The whole point of the bidirectional contract: engine off + remote true
    // must START a session using the configured default mode.
    let fixture = try RemoteBridgeFixture(
        mode: .off,
        stateOutput: #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == fixture.engine.config.defaultMode)
    #expect(await fixture.runner.recordedCalls().contains(
        ["Vibenotch", "Gotta go! turned on remotely ✓", "remote-on"]
    ))
}

@MainActor
@Test func remoteBridgePublishesLocalToggleSoThePhoneShowsTheTruth() async throws {
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        stateOutput: #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#
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
@Test func remoteBridgeReconcilesOnALocalToggleWithoutWaitingForTheNextPoll() async throws {
    // observeChanges() calls checkNow() with pollRemoteState: false. The phone
    // would still be showing "On" a poll cycle later if that path skipped the
    // reconcile, which is what the user saw as lag.
    let fixture = try RemoteBridgeFixture(mode: .manual)
    defer { fixture.remove() }
    await fixture.bridge.checkNow(pollRemoteState: true)

    fixture.engine.mode = .off
    await fixture.bridge.checkNow()

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
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0}"#
    )
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "Quiet", status: .needs_me)]

    await fixture.bridge.checkNow(pollRemoteState: true)

    // No battery/needs-me pushes while off, but state and settings reconcile
    // so the phone can both configure and start the next session.
    let calls = await fixture.runner.recordedCalls()
    #expect(calls == [["--state"]])
}

@MainActor
@Test func remoteBridgeAppliesConfigWhenRemoteRevIsHigher() async throws {
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"defaultMode":"whileAppsRunning","allowDisplaySleep":false,"batteryFloorPercent":30},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.defaultMode == .whileAppsRunning)
    #expect(!fixture.engine.config.allowDisplaySleep)
    #expect(fixture.engine.config.batteryFloorPercent == 30)
    #expect(await fixture.runner.recordedCalls() == [["--state"]])
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)
}

@MainActor
@Test func remoteBridgeSameRevIsANoOp() async throws {
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":30},"settings_rev":1}"#
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
    // Without base_rev the write is unconditional and silently overwrites a
    // phone edit made between this tick's GET and PUT.
    #expect(pushed["base_rev"] as? Int == 0)
}

@MainActor
@Test func remoteBridgeDropsTheSettingsRevBaselineWhenThePairingMovesToAnotherRemote() async throws {
    // A fresh remote restarts its counter at 0, and revs only apply when
    // strictly greater — so without this the new remote's settings would be
    // ignored until it caught up with the old one's numbering.
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":45},"settings_rev":9}"#
    )
    defer { fixture.remove() }
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(fixture.engine.config.batteryFloorPercent == 45)

    try fixture.repair(url: "https://other.example")
    let moved = try RemoteBridgeFixture(
        reusing: fixture,
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":15},"settings_rev":1}"#
    )

    await moved.bridge.checkNow(pollRemoteState: true)

    #expect(moved.engine.config.batteryFloorPercent == 15)
}

@MainActor
@Test func remoteBridgeIgnoresMalformedRemoteSettingsWithoutCrashing() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: "not json")
    defer { fixture.remove() }
    let before = fixture.engine.config

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config == before)
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)
}

@MainActor
@Test func remoteBridgeIgnoresUnknownDefaultModeStringWithoutCrashing() async throws {
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"defaultMode":"bogus","allowDisplaySleep":false},"settings_rev":1}"#
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
        stateOutput: String = #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#,
        config: KeepAwakeConfig = KeepAwakeConfig()
    ) throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = scratch.appendingPathComponent(".vibenotch", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try #"{"url":"https://remote.example","secret":"test-secret"}"#.write(
            to: configDirectory.appendingPathComponent("remote.json"),
            atomically: true,
            encoding: .utf8
        )

        engine = FakeRemoteEngine(mode: mode, isOnACPower: onAC, config: config)
        runner = FakeRemoteCommandRunner(stateOutput: stateOutput)
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

    /// Builds a second bridge over the same scratch home and UserDefaults, the
    /// way a relaunch after re-pairing would see them.
    init(reusing other: RemoteBridgeFixture, stateOutput: String) throws {
        scratch = other.scratch
        engine = other.engine
        runner = FakeRemoteCommandRunner(stateOutput: stateOutput)
        power = other.power
        suiteName = other.suiteName
        userDefaults = other.userDefaults
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: other.store,
            commandRunner: runner,
            powerSourceProvider: power,
            homeURL: scratch,
            userDefaults: userDefaults
        )
    }

    func repair(url: String) throws {
        try #"{"url":"\#(url)","secret":"test-secret"}"#.write(
            to: scratch.appendingPathComponent(".vibenotch/remote.json"),
            atomically: true,
            encoding: .utf8
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
    private var settingsPutExitCode: Int32 = 0

    init(stateOutput: String) {
        self.stateOutput = stateOutput
    }

    func setSettingsPutExitCode(_ code: Int32) {
        settingsPutExitCode = code
    }

    func run(arguments: [String], stdin: String?) async -> CommandRunResult {
        calls.append(arguments)
        stdins.append(stdin)
        if arguments == ["--settings-put"] {
            return CommandRunResult(stdout: "", exitCode: settingsPutExitCode)
        }
        return CommandRunResult(
            stdout: arguments == ["--state"] ? stateOutput : "{}",
            exitCode: 0
        )
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
