import Foundation
import IOKit.pwr_mgt
import Observation

@Observable
@MainActor
final class KeepAwakeEngine {
    private static let configKey = "keepAwake.config"
    private static let stateKey = "keepAwake.state"
    private static let assertionReason = "NotchHUD All-Nighter"
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
    private let notificationPoster: any NotificationPosting
    private let userDefaults: UserDefaults

    private var timerToken: KeepAwakeTimerToken?
    private var unlockObserverToken: KeepAwakeUnlockObserverToken?
    private let assertionLease: KeepAwakeAssertionLease
    private var graceDeadline: Date?
    private var noAgentSince: Date?
    private var didPostIdleReminder = false

    private(set) var mode: KeepAwakeMode = .off
    private(set) var activeSince: Date?
    private(set) var isOnACPower: Bool
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
        notificationPoster: any NotificationPosting = SystemNotificationPoster(),
        userDefaults: UserDefaults = .standard
    ) {
        self.sessionStore = sessionStore
        self.assertionProvider = assertionProvider
        self.runningApplicationsProvider = runningApplicationsProvider
        self.powerSourceProvider = powerSourceProvider
        self.notificationPoster = notificationPoster
        self.userDefaults = userDefaults
        self.assertionLease = KeepAwakeAssertionLease(provider: assertionProvider)
        self.isOnACPower = powerSourceProvider.isOnACPower

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
            noAgentSince = hasWorkingAgents ? nil : activeSince
        }
        remainingTime = timerRemainingTime(at: Date())
        persistConfig()
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
        let wasActive = isActive
        let modeChanged = mode != newMode
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
        isOnACPower = powerSourceProvider.isOnACPower
        guard isActive else {
            releaseAssertions()
            return
        }

        if !isOnACPower,
           let percent = powerSourceProvider.percent,
           percent <= max(10, config.batteryFloorPercent) {
            turnOff(notification: "All-Nighter: bateria baixa, a dormir", now: now)
            return
        }

        switch mode {
        case .off:
            break
        case .manual:
            break
        case let .timer(until):
            if now >= until {
                turnOff(notification: "All-Nighter terminou", now: now)
                return
            }
            remainingTime = until.timeIntervalSince(now)
        case .whileAgentsWork:
            if evaluateGrace(triggerIsActive: hasWorkingAgents, now: now) {
                turnOff(notification: "All-Nighter ended — all agents done", now: now)
                return
            }
        case .whileAppsRunning:
            let running = runningApplicationsProvider.runningBundleIdentifiers()
            let watched = Set(config.watchedBundleIDs)
            if evaluateGrace(triggerIsActive: !running.isDisjoint(with: watched), now: now) {
                turnOff(notification: "All-Nighter terminou — apps fechadas", now: now)
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

    private var hasWorkingAgents: Bool {
        sessionStore.sessions.contains {
            $0.displayStatus == .working || $0.displayStatus == .needsMe
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
        notificationPoster.post("All-Nighter ativo há \(activeHours)h sem agentes a trabalhar")
        didPostIdleReminder = true
    }

    private func turnOff(notification: String?, now: Date) {
        setMode(.off, now: now)
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
