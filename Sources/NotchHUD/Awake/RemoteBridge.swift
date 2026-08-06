import Foundation
import Observation

struct CommandRunResult: Sendable {
    let stdout: String
    let exitCode: Int32
}

protocol CommandRunning: Sendable {
    func run(arguments: [String]) async -> CommandRunResult
}

struct RemoteScriptCommandRunner: CommandRunning {
    let scriptURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        scriptURL = homeURL.appendingPathComponent(
            ".notch-hud/bin/notch-remote-push",
            isDirectory: false
        )
    }

    func run(arguments: [String]) async -> CommandRunResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = scriptURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return CommandRunResult(
                    stdout: String(decoding: data, as: UTF8.self),
                    exitCode: process.terminationStatus
                )
            } catch {
                NSLog("NotchHUD não conseguiu executar notch-remote-push: %@", error.localizedDescription)
                return CommandRunResult(stdout: "", exitCode: 127)
            }
        }.value
    }
}

@MainActor
protocol RemoteKeepAwakeEngine: AnyObject {
    var isActive: Bool { get }
    var isOnACPower: Bool { get }
    var mode: KeepAwakeMode { get }
    var lastOffReason: KeepAwakeOffReason? { get }
    func setMode(_ newMode: KeepAwakeMode, now: Date)
}

extension KeepAwakeEngine: RemoteKeepAwakeEngine {}

@MainActor
protocol RemoteSessionStoring: AnyObject {
    var sessions: [Session] { get }
}

extension SessionStore: RemoteSessionStoring {}

@MainActor
final class RemoteBridge {
    private static let batteryThresholds = [50, 30, 20]

    private let engine: any RemoteKeepAwakeEngine
    private let sessionStore: any RemoteSessionStoring
    private let commandRunner: any CommandRunning
    private let powerSourceProvider: any PowerSourceProviding
    private let pairingURL: URL

    private var timer: Timer?
    private var isStarted = false
    private var previousMode: KeepAwakeMode
    private var previousBatteryPercent: Int?
    private var sentBatteryThresholds = Set<Int>()
    private var needsMeSessionIDs = Set<String>()

    init(
        engine: any RemoteKeepAwakeEngine,
        sessionStore: any RemoteSessionStoring,
        commandRunner: (any CommandRunning)? = nil,
        powerSourceProvider: any PowerSourceProviding = SystemPowerSourceProvider(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.engine = engine
        self.sessionStore = sessionStore
        self.commandRunner = commandRunner ?? RemoteScriptCommandRunner(homeURL: homeURL)
        self.powerSourceProvider = powerSourceProvider
        pairingURL = homeURL.appendingPathComponent(".notch-hud/remote.json", isDirectory: false)
        previousMode = engine.mode
    }

    func start() {
        // isConfigured is checked per tick, so pairing created after launch
        // starts working within one poll cycle — no restart needed.
        guard !isStarted else { return }
        isStarted = true
        observeChanges()

        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkNow(pollRemoteState: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Task { @MainActor [weak self] in
            await self?.checkNow(pollRemoteState: true)
        }
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func checkNow(pollRemoteState: Bool = false) async {
        guard isConfigured else { return }

        // A failed ack-off would leave the remote state false and re-kill the
        // engine on the next activation; retry until it lands, even while off.
        if pendingAckOff {
            let ack = await run(["--ack-off"])
            if ack.exitCode == 0 {
                pendingAckOff = false
            }
        }

        let currentMode = engine.mode
        let wasActive = previousMode != .off
        let allAgentsFinished = currentMode == .off
            && previousMode == .whileAgentsWork
            && engine.lastOffReason == .whileAgentsWorkGrace

        if engine.isActive {
            await evaluateBattery()
        }

        previousMode = currentMode

        if allAgentsFinished {
            await push(
                title: "NotchHUD",
                body: "Todos os agentes terminaram — All-Nighter desligou-se",
                tag: "agents-done"
            )
        }

        guard engine.isActive else {
            previousBatteryPercent = nil
            if powerSourceProvider.snapshot().isOnACPower {
                sentBatteryThresholds.removeAll()
            }
            needsMeSessionIDs.removeAll()
            return
        }

        await evaluateNeedsMeSessions()
        if pollRemoteState {
            await pollKillSwitch()
        }
    }

    private var pendingAckOff = false

    private var isConfigured: Bool {
        FileManager.default.fileExists(atPath: pairingURL.path)
    }

    private func observeChanges() {
        withObservationTracking {
            _ = engine.mode
            _ = engine.lastOffReason
            _ = engine.isOnACPower
            _ = sessionStore.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.observeChanges()
                await self.checkNow()
            }
        }
    }

    private func evaluateBattery() async {
        let snapshot = powerSourceProvider.snapshot()
        guard !snapshot.isOnACPower else {
            previousBatteryPercent = nil
            sentBatteryThresholds.removeAll()
            return
        }
        guard let percent = snapshot.percent else { return }

        if percent > 55 {
            sentBatteryThresholds.removeAll()
        }

        if let previousBatteryPercent {
            for threshold in Self.batteryThresholds
                where previousBatteryPercent > threshold
                    && percent <= threshold
                    && !sentBatteryThresholds.contains(threshold) {
                sentBatteryThresholds.insert(threshold)
                await push(
                    title: "NotchHUD",
                    body: "Bateria a \(threshold)% — All-Nighter ativo",
                    tag: "battery-\(threshold)"
                )
            }
        }
        previousBatteryPercent = percent
    }

    private func evaluateNeedsMeSessions() async {
        var current: [String: String] = [:]
        for session in sessionStore.sessions where session.displayStatus == .needsMe {
            current[session.id] = session.project
        }
        needsMeSessionIDs.formIntersection(current.keys)

        for sessionID in current.keys.sorted()
            where !needsMeSessionIDs.contains(sessionID) {
            guard let project = current[sessionID] else { continue }
            needsMeSessionIDs.insert(sessionID)
            await push(
                title: "NotchHUD",
                body: "Precisa de ti: \(project)",
                tag: "needs-me-\(sessionID)"
            )
        }
    }

    private func pollKillSwitch() async {
        let result = await run(["--state"])
        guard result.exitCode == 0 else { return }

        struct RemoteState: Decodable {
            let keepAwakeEnabled: Bool

            enum CodingKeys: String, CodingKey {
                case keepAwakeEnabled = "keep_awake_enabled"
            }
        }

        guard let data = result.stdout.data(using: .utf8),
              let state = try? JSONDecoder().decode(RemoteState.self, from: data),
              !state.keepAwakeEnabled
        else { return }

        engine.setMode(.off, now: Date())
        let ack = await run(["--ack-off"])
        pendingAckOff = ack.exitCode != 0
        await push(
            title: "NotchHUD",
            body: "All-Nighter desligado remotamente ✓",
            tag: "remote-off"
        )
    }

    private func push(title: String, body: String, tag: String? = nil) async {
        var arguments = [title, body]
        if let tag {
            arguments.append(tag)
        }
        _ = await run(arguments)
    }

    @discardableResult
    private func run(_ arguments: [String]) async -> CommandRunResult {
        let result = await commandRunner.run(arguments: arguments)
        if result.exitCode != 0 {
            NSLog(
                "NotchHUD notch-remote-push %@ terminou com estado %d",
                arguments.first ?? "",
                result.exitCode
            )
        }
        return result
    }
}
