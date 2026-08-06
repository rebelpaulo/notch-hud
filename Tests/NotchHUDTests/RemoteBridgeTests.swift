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
@Test func remoteBridgeObeysKillSwitchThenAcknowledgesBeforeConfirming() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: #"{"keep_awake_enabled":false}"#)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == .off)
    #expect(await fixture.runner.recordedCalls() == [
        ["--state"],
        ["--ack-off"],
        ["NotchHUD", "All-Nighter desligado remotamente ✓", "remote-off"]
    ])
}

@MainActor
@Test func remoteBridgeRetriesFailedAckOffUntilItLands() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: #"{"keep_awake_enabled":false}"#)
    defer { fixture.remove() }
    await fixture.runner.setAckFailures(1)

    // obey: remote off → engine off; ack fails → pending
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(fixture.engine.mode == .off)

    // next tick (engine off): retry lands; inactive guard means no re-kill path
    await fixture.bridge.checkNow(pollRemoteState: true)
    var ackCalls = await fixture.runner.recordedCalls().filter { $0 == ["--ack-off"] }
    #expect(ackCalls.count == 2)

    // once cleared, no further ack attempts
    await fixture.bridge.checkNow(pollRemoteState: true)
    ackCalls = await fixture.runner.recordedCalls().filter { $0 == ["--ack-off"] }
    #expect(ackCalls.count == 2)
}

@MainActor
@Test func remoteBridgeMakesNoCallsWhileInitiallyInactive() async throws {
    let fixture = try RemoteBridgeFixture(mode: .off, percent: 10, onAC: false)
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "Quiet", status: .needs_me)]

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.recordedCalls().isEmpty)
}

@MainActor
private final class RemoteBridgeFixture {
    let scratch: URL
    let engine: FakeRemoteEngine
    let store = FakeRemoteStore()
    let runner: FakeRemoteCommandRunner
    let power: FakeRemotePowerSource
    let bridge: RemoteBridge

    init(
        mode: KeepAwakeMode = .manual,
        percent: Int? = 100,
        onAC: Bool = true,
        stateOutput: String = #"{"keep_awake_enabled":true}"#
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

        engine = FakeRemoteEngine(mode: mode, isOnACPower: onAC)
        runner = FakeRemoteCommandRunner(stateOutput: stateOutput)
        power = FakeRemotePowerSource(percent: percent, isOnACPower: onAC)
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: store,
            commandRunner: runner,
            powerSourceProvider: power,
            homeURL: scratch
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
    }
}

@MainActor
private final class FakeRemoteEngine: RemoteKeepAwakeEngine {
    var mode: KeepAwakeMode
    var isOnACPower: Bool
    var lastOffReason: KeepAwakeOffReason?
    var isActive: Bool { mode != .off }

    init(mode: KeepAwakeMode, isOnACPower: Bool) {
        self.mode = mode
        self.isOnACPower = isOnACPower
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
    private let stateOutput: String
    private var ackFailuresRemaining = 0

    init(stateOutput: String) {
        self.stateOutput = stateOutput
    }

    func setAckFailures(_ count: Int) {
        ackFailuresRemaining = count
    }

    func run(arguments: [String]) async -> CommandRunResult {
        calls.append(arguments)
        if arguments == ["--ack-off"], ackFailuresRemaining > 0 {
            ackFailuresRemaining -= 1
            return CommandRunResult(stdout: "", exitCode: 22)
        }
        return CommandRunResult(
            stdout: arguments == ["--state"] ? stateOutput : "{}",
            exitCode: 0
        )
    }

    func recordedCalls() -> [[String]] {
        calls
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
