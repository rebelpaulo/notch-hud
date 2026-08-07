import Foundation
import IOKit.pwr_mgt
import Testing
@testable import NotchHUD

@Test func watchedAppEditingTrimsLowercasesDeduplicatesAndRemoves() {
    let initial = [" com.OpenAI.Codex ", "", "COM.OPENAI.CODEX", " com.apple.Terminal\n"]
    let added = KeepAwakeSettingsLogic.addingWatchedBundleID("  COM.ANTHROPIC.ClaudeForDesktop ", to: initial)

    #expect(added == [
        "com.openai.codex",
        "com.apple.terminal",
        "com.anthropic.claudefordesktop"
    ])
    #expect(
        KeepAwakeSettingsLogic.removingWatchedBundleID(" COM.APPLE.Terminal ", from: added)
            == ["com.openai.codex", "com.anthropic.claudefordesktop"]
    )
}

@Test func batteryFloorSettingsClampToTenThroughFiftyPercent() {
    #expect(KeepAwakeSettingsLogic.clampedBatteryFloor(0) == 10)
    #expect(KeepAwakeSettingsLogic.clampedBatteryFloor(32) == 32)
    #expect(KeepAwakeSettingsLogic.clampedBatteryFloor(100) == 50)
}

@Test func graceMinutesRoundTripAndClampToSettingsRange() {
    #expect(KeepAwakeSettingsLogic.graceSeconds(from: 17) == 1_020)
    #expect(KeepAwakeSettingsLogic.graceMinutes(from: 1_020) == 17)
    #expect(KeepAwakeSettingsLogic.graceSeconds(from: -2) == 0)
    #expect(KeepAwakeSettingsLogic.graceSeconds(from: 90) == 3_600)
}

@MainActor
@Test func sharedConfigBindingRoundTripsThroughTheEngine() {
    let suiteName = "SettingsLogicTests.binding.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let engine = KeepAwakeEngine(
        sessionStore: SessionStore(),
        assertionProvider: SettingsSleepAssertionProvider(),
        runningApplicationsProvider: SettingsRunningApplicationsProvider(),
        powerSourceProvider: SettingsPowerSourceProvider(),
        notificationPoster: SettingsNotificationPoster(),
        userDefaults: defaults
    )
    let binding = engine.configBinding(\.allowDisplaySleep)

    #expect(binding.wrappedValue)
    binding.wrappedValue = false
    #expect(!engine.config.allowDisplaySleep)
    engine.config.allowDisplaySleep = true
    #expect(binding.wrappedValue)
}

private final class SettingsSleepAssertionProvider: SleepAssertionProviding, @unchecked Sendable {
    func create(type: String, reason: String) -> IOPMAssertionID? { 1 }
    func release(id: IOPMAssertionID) {}
}

private struct SettingsRunningApplicationsProvider: RunningApplicationsProviding, Sendable {
    func runningBundleIdentifiers() -> Set<String> { [] }
}

private struct SettingsPowerSourceProvider: PowerSourceProviding, Sendable {
    var percent: Int? = 100
    var isOnACPower = true
}

private final class SettingsNotificationPoster: NotificationPosting, @unchecked Sendable {
    func post(_ message: String) {}
}
