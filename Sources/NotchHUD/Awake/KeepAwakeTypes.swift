import Foundation
import SwiftUI

enum KeepAwakeMode: Codable, Equatable, Sendable {
    case off
    case manual
    case timer(until: Date)
    case whileAgentsWork
    case whileAppsRunning
}

struct KeepAwakeConfig: Codable, Equatable, Sendable {
    var defaultMode: KeepAwakeMode
    var allowDisplaySleep: Bool
    var closedLidMode: Bool
    var graceSeconds: TimeInterval
    var batteryFloorPercent: Int
    var acPowerOnlyForClosedLid: Bool
    var watchedBundleIDs: [String]
    var autoOffOnUnlock: Bool
    var reminderAfterIdleSeconds: TimeInterval

    init(
        defaultMode: KeepAwakeMode = .whileAgentsWork,
        allowDisplaySleep: Bool = true,
        closedLidMode: Bool = false,
        graceSeconds: TimeInterval = 600,
        batteryFloorPercent: Int = 20,
        acPowerOnlyForClosedLid: Bool = true,
        watchedBundleIDs: [String] = [
            "com.anthropic.claudefordesktop",
            "com.openai.codex",
            "com.apple.Terminal"
        ],
        autoOffOnUnlock: Bool = false,
        reminderAfterIdleSeconds: TimeInterval = 2_400
    ) {
        self.defaultMode = defaultMode == .off ? .whileAgentsWork : defaultMode
        self.allowDisplaySleep = allowDisplaySleep
        self.closedLidMode = closedLidMode
        self.graceSeconds = max(0, graceSeconds)
        self.batteryFloorPercent = max(10, min(100, batteryFloorPercent))
        self.acPowerOnlyForClosedLid = acPowerOnlyForClosedLid
        self.watchedBundleIDs = watchedBundleIDs
        self.autoOffOnUnlock = autoOffOnUnlock
        self.reminderAfterIdleSeconds = max(0, reminderAfterIdleSeconds)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultMode: try container.decodeIfPresent(KeepAwakeMode.self, forKey: .defaultMode)
                ?? .whileAgentsWork,
            allowDisplaySleep: try container.decodeIfPresent(Bool.self, forKey: .allowDisplaySleep)
                ?? true,
            closedLidMode: try container.decodeIfPresent(Bool.self, forKey: .closedLidMode)
                ?? false,
            graceSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .graceSeconds)
                ?? 600,
            batteryFloorPercent: try container.decodeIfPresent(Int.self, forKey: .batteryFloorPercent)
                ?? 20,
            acPowerOnlyForClosedLid: try container.decodeIfPresent(Bool.self, forKey: .acPowerOnlyForClosedLid)
                ?? true,
            watchedBundleIDs: try container.decodeIfPresent([String].self, forKey: .watchedBundleIDs)
                ?? ["com.anthropic.claudefordesktop", "com.openai.codex", "com.apple.Terminal"],
            autoOffOnUnlock: try container.decodeIfPresent(Bool.self, forKey: .autoOffOnUnlock)
                ?? false,
            reminderAfterIdleSeconds: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .reminderAfterIdleSeconds
            ) ?? 2_400
        )
    }
}

enum KeepAwakeSettingsLogic {
    static func normalizedWatchedBundleIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    static func addingWatchedBundleID(_ value: String, to values: [String]) -> [String] {
        normalizedWatchedBundleIDs(values + [value])
    }

    static func removingWatchedBundleID(_ value: String, from values: [String]) -> [String] {
        let target = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedWatchedBundleIDs(values).filter { $0 != target }
    }

    static func clampedBatteryFloor(_ percent: Int) -> Int {
        min(50, max(10, percent))
    }

    static func graceMinutes(from seconds: TimeInterval) -> Int {
        min(60, max(0, Int(seconds / 60)))
    }

    static func graceSeconds(from minutes: Int) -> TimeInterval {
        TimeInterval(min(60, max(0, minutes)) * 60)
    }

    static func reminderHours(from seconds: TimeInterval) -> Double {
        min(12, max(0, seconds / 3_600))
    }

    static func reminderSeconds(from hours: Double) -> TimeInterval {
        TimeInterval(min(12, max(0, hours)) * 3_600)
    }

    /// The remote API's three settable default-mode strings. `.off` and
    /// `.timer` are transient run states, never a stored default — they fall
    /// back to "whileAgentsWork", matching `KeepAwakeConfig.init` and
    /// `SettingsView.safeDefaultMode`.
    static func remoteDefaultModeString(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .whileAppsRunning: "whileAppsRunning"
        case .manual: "manual"
        default: "whileAgentsWork"
        }
    }

    static func defaultMode(fromRemote value: String) -> KeepAwakeMode? {
        switch value {
        case "whileAgentsWork": .whileAgentsWork
        case "whileAppsRunning": .whileAppsRunning
        case "manual": .manual
        default: nil
        }
    }
}

@MainActor
extension KeepAwakeEngine {
    func configBinding<Value>(_ keyPath: WritableKeyPath<KeepAwakeConfig, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { self.config[keyPath: keyPath] = $0 }
        )
    }
}
