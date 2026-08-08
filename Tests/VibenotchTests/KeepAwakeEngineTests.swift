import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Vibenotch

@MainActor
@Test func whileAgentsWorkUsesGraceAndCancelsItWhenWorkResumes() {
    let fixture = KeepAwakeFixture()
    let start = Date(timeIntervalSince1970: 1_000_000)
    fixture.engine.config.graceSeconds = 10
    fixture.store.apply([makeAwakeSession(status: .working)])

    fixture.engine.setMode(.whileAgentsWork, now: start)
    fixture.engine.tick(now: start)
    #expect(fixture.engine.isActive)
    #expect(fixture.assertions.activeIDs.count == 1)

    fixture.store.apply([makeAwakeSession(status: .done)])
    fixture.engine.tick(now: start.addingTimeInterval(1))
    fixture.store.apply([makeAwakeSession(status: .needs_me)])
    fixture.engine.tick(now: start.addingTimeInterval(8))

    fixture.store.apply([makeAwakeSession(status: .done)])
    fixture.engine.tick(now: start.addingTimeInterval(10))
    fixture.engine.tick(now: start.addingTimeInterval(19))
    #expect(fixture.engine.isActive)

    fixture.engine.tick(now: start.addingTimeInterval(20))
    #expect(fixture.engine.mode == .off)
    #expect(fixture.assertions.activeIDs.isEmpty)
    #expect(fixture.notifications.messages == [
        "Gotta go! finished — all agents done"
    ])
}

@MainActor
@Test func batteryFloorForcesOffAndCannotBeLoweredBelowTenPercent() {
    let fixture = KeepAwakeFixture(percent: 10, isOnACPower: false)
    fixture.engine.config.batteryFloorPercent = 0
    fixture.engine.setMode(.manual)

    fixture.engine.tick()

    #expect(fixture.engine.mode == .off)
    #expect(fixture.assertions.activeIDs.isEmpty)
    #expect(fixture.notifications.messages == ["Gotta go!: battery low, going to sleep"])
}

@MainActor
@Test func timerExpiryTurnsEngineOffAndReportsNoRemainingTime() {
    let fixture = KeepAwakeFixture()
    let start = Date(timeIntervalSince1970: 2_000_000)
    let expiry = start.addingTimeInterval(60)
    fixture.engine.setMode(.timer(until: expiry), now: start)

    #expect(fixture.engine.remainingTime == 60)
    #expect(fixture.engine.remainingTime(at: start.addingTimeInterval(15)) == 45)
    fixture.engine.tick(now: start.addingTimeInterval(15))
    #expect(fixture.engine.remainingTime == 45)
    fixture.engine.tick(now: expiry)

    #expect(fixture.engine.mode == .off)
    #expect(fixture.engine.remainingTime == nil)
    #expect(fixture.engine.remainingTime(at: expiry) == nil)
    #expect(fixture.assertions.activeIDs.isEmpty)
}

@MainActor
@Test func whileAppsRunningFollowsWatchedApplicationsThroughGrace() {
    let apps = FakeRunningApplications(bundleIDs: ["com.openai.codex"])
    let fixture = KeepAwakeFixture(applications: apps)
    let start = Date(timeIntervalSince1970: 3_000_000)
    fixture.engine.config.graceSeconds = 5
    fixture.engine.setMode(.whileAppsRunning, now: start)
    fixture.engine.tick(now: start)
    #expect(fixture.engine.isActive)

    apps.bundleIDs = []
    fixture.engine.tick(now: start.addingTimeInterval(1))
    fixture.engine.tick(now: start.addingTimeInterval(5))
    #expect(fixture.engine.isActive)

    fixture.engine.tick(now: start.addingTimeInterval(6))
    #expect(fixture.engine.mode == .off)
    #expect(fixture.assertions.activeIDs.isEmpty)
}

@MainActor
@Test func displaySleepAssertionExistsOnlyWhenDisplaySleepIsDisallowed() {
    let fixture = KeepAwakeFixture()
    fixture.engine.setMode(.manual)

    #expect(fixture.assertions.createdTypes == [
        kIOPMAssertionTypePreventUserIdleSystemSleep as String
    ])

    fixture.engine.config.allowDisplaySleep = false
    #expect(fixture.assertions.createdTypes == [
        kIOPMAssertionTypePreventUserIdleSystemSleep as String,
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String
    ])

    fixture.engine.config.allowDisplaySleep = true
    #expect(fixture.assertions.activeIDs.count == 1)
}

@MainActor
@Test func persistedConfigAndManualModeRestoreInFreshEngine() {
    let suiteName = "KeepAwakeEngineTests.restore.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstAssertions = FakeSleepAssertionProvider()
    var first: KeepAwakeEngine? = KeepAwakeEngine(
        sessionStore: SessionStore(),
        assertionProvider: firstAssertions,
        runningApplicationsProvider: FakeRunningApplications(),
        powerSourceProvider: FakePowerSource(),
        notificationPoster: FakeNotificationPoster(),
        userDefaults: defaults
    )
    first?.config.closedLidMode = true
    first?.config.reminderAfterIdleSeconds = 3_600
    first?.setMode(.manual, now: Date(timeIntervalSince1970: 4_000_000))
    first = nil
    #expect(firstAssertions.createCount == firstAssertions.releaseCount)

    let notifications = FakeNotificationPoster()
    let beforeRestore = Date()
    let second = KeepAwakeEngine(
        sessionStore: SessionStore(),
        assertionProvider: FakeSleepAssertionProvider(),
        runningApplicationsProvider: FakeRunningApplications(),
        powerSourceProvider: FakePowerSource(),
        notificationPoster: notifications,
        userDefaults: defaults
    )

    #expect(second.mode == .manual)
    #expect(second.activeSince == Date(timeIntervalSince1970: 4_000_000))
    #expect(second.config.closedLidMode)
    #expect(second.wantsClosedLidAwake)
    second.tick(now: beforeRestore.addingTimeInterval(3_599))
    #expect(notifications.messages.isEmpty)
    second.tick(now: beforeRestore.addingTimeInterval(3_601))
    #expect(notifications.messages.count == 1)
}

@Test func missingInternalBatteryIsTreatedAsACPower() {
    #expect(SystemPowerSourceProvider.isOnACPower(batteryDescription: nil))
}

@MainActor
@Test func assertionsBalanceAcrossModeAndDisplayPolicyChurn() {
    let fixture = KeepAwakeFixture()

    fixture.engine.setMode(.manual)
    fixture.engine.setMode(.timer(until: Date().addingTimeInterval(60)))
    fixture.engine.config.allowDisplaySleep = false
    fixture.engine.config.allowDisplaySleep = true
    fixture.engine.setMode(.off)
    fixture.engine.setMode(.whileAgentsWork)
    fixture.engine.stop()

    #expect(fixture.assertions.activeIDs.isEmpty)
    #expect(fixture.assertions.createCount == fixture.assertions.releaseCount)
}

@MainActor
@Test func idleReminderPostsOnlyOncePerActivation() {
    let fixture = KeepAwakeFixture()
    let start = Date(timeIntervalSince1970: 5_000_000)
    fixture.engine.config.reminderAfterIdleSeconds = 3_600
    fixture.engine.setMode(.manual, now: start)

    fixture.engine.tick(now: start.addingTimeInterval(3_600))
    fixture.engine.tick(now: start.addingTimeInterval(7_200))

    #expect(fixture.notifications.messages == [
        "Gotta go! on for 1h with no agents working"
    ])
}

@MainActor
private final class KeepAwakeFixture {
    let store = SessionStore()
    let assertions = FakeSleepAssertionProvider()
    let notifications = FakeNotificationPoster()
    let engine: KeepAwakeEngine
    private let suiteName: String
    private let defaults: UserDefaults

    init(
        percent: Int? = 100,
        isOnACPower: Bool = true,
        applications: FakeRunningApplications = FakeRunningApplications()
    ) {
        suiteName = "KeepAwakeEngineTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        engine = KeepAwakeEngine(
            sessionStore: store,
            assertionProvider: assertions,
            runningApplicationsProvider: applications,
            powerSourceProvider: FakePowerSource(percent: percent, isOnACPower: isOnACPower),
            notificationPoster: notifications,
            userDefaults: defaults
        )
    }

}

private final class FakeSleepAssertionProvider: SleepAssertionProviding, @unchecked Sendable {
    private(set) var createdTypes: [String] = []
    private(set) var releasedIDs: [IOPMAssertionID] = []
    private(set) var activeIDs = Set<IOPMAssertionID>()
    private var nextID: IOPMAssertionID = 1

    var createCount: Int { createdTypes.count }
    var releaseCount: Int { releasedIDs.count }

    func create(type: String, reason: String) -> IOPMAssertionID? {
        let id = nextID
        nextID += 1
        createdTypes.append(type)
        activeIDs.insert(id)
        return id
    }

    func release(id: IOPMAssertionID) {
        releasedIDs.append(id)
        activeIDs.remove(id)
    }
}

private final class FakeRunningApplications: RunningApplicationsProviding, @unchecked Sendable {
    var bundleIDs: Set<String>

    init(bundleIDs: Set<String> = []) {
        self.bundleIDs = bundleIDs
    }

    func runningBundleIdentifiers() -> Set<String> {
        bundleIDs
    }
}

private final class FakePowerSource: PowerSourceProviding, @unchecked Sendable {
    var percent: Int?
    var isOnACPower: Bool

    init(percent: Int? = 100, isOnACPower: Bool = true) {
        self.percent = percent
        self.isOnACPower = isOnACPower
    }
}

private final class FakeNotificationPoster: NotificationPosting, @unchecked Sendable {
    private(set) var messages: [String] = []

    func post(_ message: String) {
        messages.append(message)
    }
}

private func makeAwakeSession(status: SessionStatus) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: UUID().uuidString,
            agent: "codex",
            status: status,
            updated: "2026-08-06T12:00:00Z",
            seq: 1
        ),
        updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}
