import Foundation
import Observation

struct CommandRunResult: Sendable {
    let stdout: String
    let exitCode: Int32
}

protocol CommandRunning: Sendable {
    func run(arguments: [String], stdin: String?) async -> CommandRunResult
}

extension CommandRunning {
    func run(arguments: [String]) async -> CommandRunResult {
        await run(arguments: arguments, stdin: nil)
    }
}

struct RemoteScriptCommandRunner: CommandRunning {
    let scriptURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        scriptURL = homeURL.appendingPathComponent(
            ".notch-hud/bin/notch-remote-push",
            isDirectory: false
        )
    }

    func run(arguments: [String], stdin: String? = nil) async -> CommandRunResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = scriptURL
            process.arguments = arguments
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                // ponytail: writes the whole (small, <1KB settings JSON) body
                // before draining stdout; fine at this payload size, would
                // need concurrent read/write pumps if stdin ever got large.
                if let stdin {
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                }
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return CommandRunResult(
                    stdout: String(decoding: data, as: UTF8.self),
                    exitCode: process.terminationStatus
                )
            } catch {
                NSLog("NotchHUD could not run notch-remote-push: %@", error.localizedDescription)
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
    var config: KeepAwakeConfig { get set }
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
    private static let lastAppliedSettingsRevKey = "remoteBridge.lastAppliedSettingsRev"

    private let engine: any RemoteKeepAwakeEngine
    private let sessionStore: any RemoteSessionStoring
    private let commandRunner: any CommandRunning
    private let powerSourceProvider: any PowerSourceProviding
    private let pairingURL: URL
    private let userDefaults: UserDefaults

    private var timer: Timer?
    private var isStarted = false
    private var previousMode: KeepAwakeMode
    private var previousBatteryPercent: Int?
    private var sentBatteryThresholds = Set<Int>()
    private var needsMeSessionIDs = Set<String>()
    // The config snapshot we last know to be in sync with the remote —
    // either just applied from a newer remote rev, or just pushed up.
    // Diverging from it locally is what triggers a --settings-put.
    private var lastSyncedSettingsSnapshot: RemoteSettingsSnapshot

    private var lastAppliedSettingsRev: Int {
        get { userDefaults.integer(forKey: Self.lastAppliedSettingsRevKey) }
        set { userDefaults.set(newValue, forKey: Self.lastAppliedSettingsRevKey) }
    }

    init(
        engine: any RemoteKeepAwakeEngine,
        sessionStore: any RemoteSessionStoring,
        commandRunner: (any CommandRunning)? = nil,
        powerSourceProvider: any PowerSourceProviding = SystemPowerSourceProvider(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        userDefaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.sessionStore = sessionStore
        self.commandRunner = commandRunner ?? RemoteScriptCommandRunner(homeURL: homeURL)
        self.powerSourceProvider = powerSourceProvider
        self.userDefaults = userDefaults
        pairingURL = homeURL.appendingPathComponent(".notch-hud/remote.json", isDirectory: false)
        previousMode = engine.mode
        lastSyncedSettingsSnapshot = RemoteSettingsSnapshot(engine.config)
    }

    func start() {
        // isConfigured is checked per tick, so pairing created after launch
        // starts working within one poll cycle — no restart needed.
        guard !isStarted else { return }
        isStarted = true
        observeChanges()

        // 10s: the phone's own UI refreshes on the same order, so a toggle on
        // either side lands within about ten seconds. One GET per tick (state
        // and settings share /api/state), so this is the same request volume
        // the 45s two-call version had.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
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

        let currentMode = engine.mode
        let allAgentsFinished = currentMode == .off
            && previousMode == .whileAgentsWork
            && engine.lastOffReason == .whileAgentsWorkGrace

        if engine.isActive {
            await evaluateBattery()
        }

        previousMode = currentMode

        // A local toggle reconciles right away instead of waiting for the next
        // poll tick — observeChanges() calls this the moment the bolt flips, so
        // the phone sees the new state in about a second. It goes through the
        // same reconcile as a timer tick (rather than pushing straight up) so
        // there is exactly one place that decides which side wins.
        let toggledLocally = lastSyncedActive.map { $0 != engine.isActive } ?? false

        if allAgentsFinished {
            await push(
                title: "NotchHUD",
                body: t("All agents finished — Gotta go! turned itself off"),
                tag: "agents-done"
            )
        }

        guard engine.isActive else {
            previousBatteryPercent = nil
            if powerSourceProvider.snapshot().isOnACPower {
                sentBatteryThresholds.removeAll()
            }
            needsMeSessionIDs.removeAll()
            // Settings AND the on/off state must sync while Gotta go! is off:
            // the phone configures the next session, and turning it ON remotely
            // is only reachable from here. (Battery/needs-me pushes stay
            // active-only.)
            if pollRemoteState || toggledLocally {
                await reconcileRemote()
            }
            return
        }

        await evaluateNeedsMeSessions()
        if pollRemoteState || toggledLocally {
            await reconcileRemote()
        }
    }

    // nil until the first successful reconcile; then the on/off value both
    // sides last agreed on, so a local toggle can be told apart from a stale
    // remote flag.
    private var lastSyncedActive: Bool?

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
                    body: t("Battery at %d%% — Gotta go! is on", threshold),
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
                body: t("Needs you: %@", project),
                tag: "needs-me-\(sessionID)"
            )
        }
    }

    /// The remote flag is the DESIRED state, reconciled in both directions:
    /// the phone can start a session as well as kill one, and a local toggle
    /// is pushed up so the phone never shows a stale answer. (It used to be
    /// kill-only, with an ack that reset the flag to true — which is exactly
    /// why turning Gotta go! *on* from the phone did nothing.)
    /// /api/state answers with the on/off flag AND the settings blob, so one
    /// GET per tick feeds both reconcilers.
    private func reconcileRemote() async {
        let result = await run(["--state"])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let remote = try? JSONDecoder().decode(RemoteStateWithSettings.self, from: data)
        else { return }

        if let desired = remote.keepAwakeEnabled {
            await reconcileDesiredState(desired)
        }
        await reconcileSettings(remote)
    }

    private func reconcileDesiredState(_ desired: Bool) async {
        let isActive = engine.isActive
        if desired == isActive {
            lastSyncedActive = isActive
            return
        }

        // Toggled on the Mac since the last agreement: the local truth wins and
        // is published, so the phone shows "On" when you flip the bolt here.
        // (On the very first reconcile there is nothing to compare against, so
        // the remote value is treated as the desired state.)
        if let lastSyncedActive, lastSyncedActive != isActive {
            await pushDesiredState(isActive)
            return
        }

        if desired {
            let startMode = engine.config.defaultMode == .off
                ? KeepAwakeMode.whileAgentsWork
                : engine.config.defaultMode
            engine.setMode(startMode, now: Date())
            lastSyncedActive = engine.isActive
            await push(
                title: "NotchHUD",
                body: t("Gotta go! turned on remotely ✓"),
                tag: "remote-on"
            )
        } else {
            engine.setMode(.off, now: Date())
            lastSyncedActive = false
            await push(
                title: "NotchHUD",
                body: t("Gotta go! turned off remotely ✓"),
                tag: "remote-off"
            )
        }
    }

    private func pushDesiredState(_ enabled: Bool) async {
        let body = #"{"keep_awake_enabled":\#(enabled)}"#
        let result = await run(["--state-put"], stdin: body)
        if result.exitCode == 0 {
            lastSyncedActive = enabled
        }
    }

    private func push(title: String, body: String, tag: String? = nil) async {
        var arguments = [title, body]
        if let tag {
            arguments.append(tag)
        }
        _ = await run(arguments)
    }

    // Remote rev wins on conflict: a newer remote rev always overwrites the
    // local config and re-baselines the sync snapshot, so the same tick
    // never also pushes local values back up for that rev. Only once the
    // rev is caught up do local edits get a chance to push.
    private func reconcileSettings(_ remote: RemoteStateWithSettings) async {
        let remoteRev = remote.settingsRev ?? 0
        if remoteRev > lastAppliedSettingsRev {
            if let settings = remote.settings {
                applyRemoteSettings(settings)
            }
            lastAppliedSettingsRev = remoteRev
            lastSyncedSettingsSnapshot = RemoteSettingsSnapshot(engine.config)
            return
        }

        let currentSnapshot = RemoteSettingsSnapshot(engine.config)
        guard currentSnapshot != lastSyncedSettingsSnapshot else { return }

        guard let body = try? JSONSerialization.data(withJSONObject: ["settings": currentSnapshot.remoteJSONObject]),
              let stdin = String(data: body, encoding: .utf8)
        else { return }

        let pushResult = await run(["--settings-put"], stdin: stdin)
        if pushResult.exitCode == 0 {
            // Next poll's --state will see the bumped rev and re-apply
            // these same values as if they were a remote change — harmless,
            // since applying them is a no-op once the snapshot already
            // matches. That one-cycle-lag keeps this side simple.
            lastSyncedSettingsSnapshot = currentSnapshot
        }
    }

    private func applyRemoteSettings(_ settings: RemoteSettingsPayload) {
        var config = engine.config
        if let modeString = settings.defaultMode,
           let mode = KeepAwakeSettingsLogic.defaultMode(fromRemote: modeString) {
            config.defaultMode = mode
        }
        if let value = settings.allowDisplaySleep { config.allowDisplaySleep = value }
        if let value = settings.closedLidMode { config.closedLidMode = value }
        if let value = settings.autoOffOnUnlock { config.autoOffOnUnlock = value }
        if let value = settings.batteryFloorPercent {
            config.batteryFloorPercent = KeepAwakeSettingsLogic.clampedBatteryFloor(value)
        }
        if let value = settings.graceMinutes {
            config.graceSeconds = KeepAwakeSettingsLogic.graceSeconds(from: value)
        }
        if let value = settings.reminderHours {
            config.reminderAfterIdleSeconds = KeepAwakeSettingsLogic.reminderSeconds(from: value)
        }
        engine.config = config
    }

    @discardableResult
    private func run(_ arguments: [String], stdin: String? = nil) async -> CommandRunResult {
        let result = await commandRunner.run(arguments: arguments, stdin: stdin)
        if result.exitCode != 0 {
            NSLog(
                "NotchHUD notch-remote-push %@ exited with status %d",
                arguments.first ?? "",
                result.exitCode
            )
        }
        return result
    }
}

/// The seven remote-managed fields of `KeepAwakeConfig`, mapped to the wire
/// format used by /api/state and /api/settings. Equatable so RemoteBridge
/// can detect local drift with a plain `!=` against the last-synced value.
private struct RemoteSettingsSnapshot: Equatable {
    var defaultMode: String
    var allowDisplaySleep: Bool
    var closedLidMode: Bool
    var autoOffOnUnlock: Bool
    var batteryFloorPercent: Int
    var graceMinutes: Int
    var reminderHours: Double

    init(_ config: KeepAwakeConfig) {
        defaultMode = KeepAwakeSettingsLogic.remoteDefaultModeString(config.defaultMode)
        allowDisplaySleep = config.allowDisplaySleep
        closedLidMode = config.closedLidMode
        autoOffOnUnlock = config.autoOffOnUnlock
        batteryFloorPercent = config.batteryFloorPercent
        graceMinutes = KeepAwakeSettingsLogic.graceMinutes(from: config.graceSeconds)
        reminderHours = KeepAwakeSettingsLogic.reminderHours(from: config.reminderAfterIdleSeconds)
    }

    var remoteJSONObject: [String: Any] {
        [
            "defaultMode": defaultMode,
            "allowDisplaySleep": allowDisplaySleep,
            "closedLidMode": closedLidMode,
            "autoOffOnUnlock": autoOffOnUnlock,
            "batteryFloorPercent": batteryFloorPercent,
            "graceMinutes": graceMinutes,
            "reminderHours": reminderHours,
        ]
    }
}

private struct RemoteSettingsPayload: Decodable {
    var defaultMode: String?
    var allowDisplaySleep: Bool?
    var closedLidMode: Bool?
    var autoOffOnUnlock: Bool?
    var batteryFloorPercent: Int?
    var graceMinutes: Int?
    var reminderHours: Double?
}

private struct RemoteStateWithSettings: Decodable {
    let keepAwakeEnabled: Bool?
    let settings: RemoteSettingsPayload?
    let settingsRev: Int?

    enum CodingKeys: String, CodingKey {
        case keepAwakeEnabled = "keep_awake_enabled"
        case settings
        case settingsRev = "settings_rev"
    }
}
