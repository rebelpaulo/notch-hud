import Foundation
import IOKit.pwr_mgt
import Observation

enum KeepAwakeOffReason: Equatable, Sendable {
    case whileAgentsWorkGrace
}

@Observable
@MainActor
final class KeepAwakeEngine {
    private static let configKey = "keepAwake.config"
    private static let stateKey = "keepAwake.state"
    private static let assertionReason = "Vibenotch Gotta go!"
    private static let systemSleepAssertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as String
    private static let displaySleepAssertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as String

    private struct PersistedState: Codable {
        let mode: KeepAwakeMode
        let activeSince: Date?
    }

    private let sessionStore: SessionStore
    private let assertionProvider: any SleepAssertionProviding
    private let runningApplicationsProvider: any RunningApplicationsProviding
    private let powerSourceProvider: any PowerSourceProviding
    private let thermalStateProvider: any ThermalStateProviding
    private let notificationPoster: any NotificationPosting
    private let userDefaults: UserDefaults

    private var timerToken: KeepAwakeTimerToken?
    private var unlockObserverToken: KeepAwakeUnlockObserverToken?
    private let assertionLease: KeepAwakeAssertionLease
    private var graceDeadline: Date?
    private var noAgentSince: Date?
    private var didPostIdleReminder = false
    /// Re-armed when the Mac leaves `critical`, so a second episode is reported
    /// but a single one is not reported sixty times a minute.
    private var didReportCriticalHeat = false

    private(set) var mode: KeepAwakeMode = .off
    private(set) var lastOffReason: KeepAwakeOffReason?
    private(set) var activeSince: Date?
    private(set) var isOnACPower: Bool
    /// Refreshed on the tick rather than read live, so the notch and the phone
    /// always show the same reading the auto-off decision was made from.
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var remainingTime: TimeInterval?
    var config: KeepAwakeConfig {
        didSet {
            persistConfig()
            reconcileAssertions()
        }
    }

    var isActive: Bool {
        mode != .off
    }

    var wantsClosedLidAwake: Bool {
        isActive
            && config.closedLidMode
            && (isOnACPower || !config.acPowerOnlyForClosedLid)
    }

    init(
        sessionStore: SessionStore,
        assertionProvider: any SleepAssertionProviding = SystemSleepAssertionProvider(),
        runningApplicationsProvider: any RunningApplicationsProviding = SystemRunningApplicationsProvider(),
        powerSourceProvider: any PowerSourceProviding = SystemPowerSourceProvider(),
        thermalStateProvider: any ThermalStateProviding = SystemThermalStateProvider(),
        notificationPoster: any NotificationPosting = SystemNotificationPoster(),
        userDefaults: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.assertionProvider = assertionProvider
        self.runningApplicationsProvider = runningApplicationsProvider
        self.powerSourceProvider = powerSourceProvider
        self.thermalStateProvider = thermalStateProvider
        self.notificationPoster = notificationPoster
        self.userDefaults = userDefaults
        self.assertionLease = KeepAwakeAssertionLease(provider: assertionProvider)
        self.isOnACPower = powerSourceProvider.snapshot().isOnACPower
        self.thermalState = thermalStateProvider.thermalState
        let restoreTime = Date()

        if let data = userDefaults.data(forKey: Self.configKey),
           let restoredConfig = try? JSONDecoder().decode(KeepAwakeConfig.self, from: data) {
            config = restoredConfig
        } else {
            config = KeepAwakeConfig()
        }

        if let data = userDefaults.data(forKey: Self.stateKey),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            mode = state.mode
            activeSince = state.mode == .off ? nil : state.activeSince
        }

        if isActive {
            noAgentSince = hasWorkingAgents ? nil : restoreTime
        }
        remainingTime = timerRemainingTime(at: restoreTime)
        persistConfig()

        // Launching into a Mac that is ALREADY critical, with a session
        // restored from disk, would otherwise hold the assertions until the
        // first tick — the app would start by keeping a machine awake that it
        // is about to declare too hot to keep awake. Decide before creating
        // them, not after.
        if isActive, thermalState == .critical {
            reportCriticalHeat(now: restoreTime)
        }

        reconcileAssertions()
    }

    func start() {
        guard timerToken == nil else { return }

        installUnlockObserver()
        tick()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timerToken = KeepAwakeTimerToken(timer: timer)
    }

    func stop() {
        timerToken?.invalidate()
        timerToken = nil
        unlockObserverToken = nil
        releaseAssertions()
    }

    func setMode(_ newMode: KeepAwakeMode, now: Date = Date()) {
        // Refused here rather than left for the next tick to undo. Turning on
        // into a critical Mac would light the bolt, post a shutdown notice five
        // seconds later, and do the same again on the next attempt — from the
        // notch, from the phone, and from the remote reconciler, each one
        // costing a notification.
        thermalState = thermalStateProvider.thermalState
        if newMode != .off, thermalState == .critical {
            reportCriticalHeat(now: now)
            return
        }
        applyMode(newMode, now: now, offReason: nil)
    }

    private func applyMode(
        _ newMode: KeepAwakeMode,
        now: Date,
        offReason: KeepAwakeOffReason?
    ) {
        let wasActive = isActive
        let modeChanged = mode != newMode
        lastOffReason = newMode == .off ? offReason : nil
        mode = newMode
        graceDeadline = nil
        remainingTime = timerRemainingTime(at: now)

        if newMode == .off {
            activeSince = nil
            noAgentSince = nil
            didPostIdleReminder = false
        } else if modeChanged || !wasActive {
            activeSince = now
            noAgentSince = hasWorkingAgents ? nil : now
            didPostIdleReminder = false
        }

        persistState()
        reconcileAssertions()
    }

    func tick(now: Date = Date()) {
        let powerSource = powerSourceProvider.snapshot()
        isOnACPower = powerSource.isOnACPower
        thermalState = thermalStateProvider.thermalState
        if thermalState != .critical { didReportCriticalHeat = false }
        guard isActive else {
            releaseAssertions()
            return
        }

        if !isOnACPower,
           let percent = powerSource.percent,
           percent <= max(10, config.batteryFloorPercent) {
            turnOff(notification: t("Gotta go!: battery low, going to sleep"), now: now)
            return
        }

        // Critical only. macOS reports `serious` for any sustained load — a long
        // build hits it on a healthy machine — so acting there would turn Gotta
        // go! off during exactly the work it exists to protect. `critical` means
        // the system is already shedding performance to survive, and holding the
        // Mac awake past that point buys nothing: the agents are being throttled
        // anyway, and the heat has nowhere to go with the lid shut.
        if thermalState == .critical {
            reportCriticalHeat(now: now)
            return
        }

        switch mode {
        case .off:
            break
        case .manual:
            break
        case let .timer(until):
            if now >= until {
                turnOff(notification: t("Gotta go! finished"), now: now)
                return
            }
            remainingTime = until.timeIntervalSince(now)
        case .whileAgentsWork:
            if evaluateGrace(triggerIsActive: hasWorkingAgents, now: now) {
                turnOff(
                    notification: t("Gotta go! finished — all agents done"),
                    reason: .whileAgentsWorkGrace,
                    now: now
                )
                return
            }
        case .whileAppsRunning:
            let running = runningApplicationsProvider.runningBundleIdentifiers()
            let watched = Set(config.watchedBundleIDs)
            if evaluateGrace(triggerIsActive: !running.isDisjoint(with: watched), now: now) {
                turnOff(notification: t("Gotta go! finished — apps closed"), now: now)
                return
            }
        }

        evaluateIdleReminder(now: now)
        reconcileAssertions()
    }

    func remainingTime(at now: Date = Date()) -> TimeInterval? {
        timerRemainingTime(at: now)
    }

    private func timerRemainingTime(at now: Date) -> TimeInterval? {
        guard case let .timer(until) = mode else { return nil }
        return max(0, until.timeIntervalSince(now))
    }

    /// Whether anything is still going — for the purpose of keeping the Mac
    /// awake, which is a lower bar than "is definitely running".
    ///
    /// `.idle` (a `.unknown` status) counts, and that is the point. The hook
    /// writes on PreToolUse, Stop and Notification — there is no PostToolUse
    /// and no heartbeat — so a session doing ONE long thing writes once when
    /// the tool starts and then says nothing until the next one. After 90
    /// seconds StalenessSweeper demotes it to `.unknown`, and treating that as
    /// finished started the grace countdown under a live agent: about eleven
    /// and a half minutes into a long build or test run, the Mac went to sleep
    /// on top of it.
    ///
    /// "I do not know what this agent is doing" is not "this agent finished".
    /// The sweeper already owns the question of when a session is really gone
    /// — it removes it at `dropSeconds` — so holding the machine awake until
    /// then costs at most a few idle minutes, while getting it wrong costs the
    /// work. Only `.done`, which the agent said about itself, ends the watch.
    private var hasWorkingAgents: Bool {
        sessionStore.sessions.contains {
            switch $0.displayStatus {
            case .working, .needsMe, .idle: true
            case .done: false
            }
        }
    }

    private func evaluateGrace(triggerIsActive: Bool, now: Date) -> Bool {
        if triggerIsActive {
            graceDeadline = nil
            return false
        }

        if graceDeadline == nil {
            graceDeadline = now.addingTimeInterval(max(0, config.graceSeconds))
        }
        return now >= graceDeadline!
    }

    private func evaluateIdleReminder(now: Date) {
        guard config.reminderAfterIdleSeconds > 0, !didPostIdleReminder else { return }

        if hasWorkingAgents {
            noAgentSince = nil
            return
        }
        if noAgentSince == nil {
            noAgentSince = now
        }
        guard let noAgentSince,
              now.timeIntervalSince(noAgentSince) >= config.reminderAfterIdleSeconds
        else { return }

        let activeHours = max(1, Int(now.timeIntervalSince(activeSince ?? now) / 3_600))
        notificationPoster.post(t("Gotta go! on for %dh with no agents working", activeHours))
        didPostIdleReminder = true
    }

    /// Shuts down for heat, and says so ONCE per critical episode.
    ///
    /// The latch is the point. Without it a Mac sitting at critical posts a
    /// notification every five seconds, and every rejected attempt to turn
    /// Gotta go! back on posts another — which is how a safety feature turns
    /// into the reason someone mutes the app's notifications entirely.
    private func reportCriticalHeat(now: Date) {
        // "Going to sleep" is a claim about something that was awake. Refusing
        // to START while the Mac is already too hot goes through here too, and
        // announcing a shutdown that never happened describes an event the
        // user did not have. Still marked as reported, so the message is not
        // saved up to fire later out of context.
        guard isActive else {
            didReportCriticalHeat = true
            return
        }

        turnOff(
            notification: didReportCriticalHeat ? nil : t("Gotta go!: Mac too hot, going to sleep"),
            now: now
        )
        didReportCriticalHeat = true
    }

    private func turnOff(
        notification: String?,
        reason: KeepAwakeOffReason? = nil,
        now: Date
    ) {
        applyMode(.off, now: now, offReason: reason)
        if let notification {
            notificationPoster.post(notification)
        }
    }

    private func installUnlockObserver() {
        guard unlockObserverToken == nil else { return }
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.config.autoOffOnUnlock, self.isActive else { return }
                self.setMode(.off)
            }
        }
        unlockObserverToken = KeepAwakeUnlockObserverToken(observer: observer)
    }

    private func reconcileAssertions() {
        guard isActive else {
            releaseAssertions()
            return
        }

        if assertionLease.systemSleepAssertionID == nil {
            assertionLease.systemSleepAssertionID = assertionProvider.create(
                type: Self.systemSleepAssertionType,
                reason: Self.assertionReason
            )
            if assertionLease.systemSleepAssertionID == nil {
                NSLog(
                    "Vibenotch could not create the power assertion '%@'; the Mac may sleep.",
                    Self.systemSleepAssertionType
                )
            }
        }

        if config.allowDisplaySleep {
            if let displaySleepAssertionID = assertionLease.displaySleepAssertionID {
                assertionProvider.release(id: displaySleepAssertionID)
                assertionLease.displaySleepAssertionID = nil
            }
        } else if assertionLease.displaySleepAssertionID == nil {
            assertionLease.displaySleepAssertionID = assertionProvider.create(
                type: Self.displaySleepAssertionType,
                reason: Self.assertionReason
            )
            if assertionLease.displaySleepAssertionID == nil {
                NSLog(
                    "Vibenotch could not create the power assertion '%@'; the display may sleep.",
                    Self.displaySleepAssertionType
                )
            }
        }
    }

    private func releaseAssertions() {
        assertionLease.releaseAll()
    }

    private func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        userDefaults.set(data, forKey: Self.configKey)
    }

    private func persistState() {
        let state = PersistedState(mode: mode, activeSince: activeSince)
        guard let data = try? JSONEncoder().encode(state) else { return }
        userDefaults.set(data, forKey: Self.stateKey)
    }
}

private final class KeepAwakeAssertionLease: @unchecked Sendable {
    let provider: any SleepAssertionProviding
    var systemSleepAssertionID: IOPMAssertionID?
    var displaySleepAssertionID: IOPMAssertionID?

    init(provider: any SleepAssertionProviding) {
        self.provider = provider
    }

    deinit {
        releaseAll()
    }

    func releaseAll() {
        if let displaySleepAssertionID {
            provider.release(id: displaySleepAssertionID)
            self.displaySleepAssertionID = nil
        }
        if let systemSleepAssertionID {
            provider.release(id: systemSleepAssertionID)
            self.systemSleepAssertionID = nil
        }
    }
}

private final class KeepAwakeTimerToken: @unchecked Sendable {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    deinit {
        timer.invalidate()
    }

    func invalidate() {
        timer.invalidate()
    }
}

private final class KeepAwakeUnlockObserverToken: @unchecked Sendable {
    private let observer: NSObjectProtocol

    init(observer: NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(observer)
    }
}
