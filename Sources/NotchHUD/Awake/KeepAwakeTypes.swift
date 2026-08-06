import Foundation

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
