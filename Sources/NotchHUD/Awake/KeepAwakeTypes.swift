import Foundation

enum KeepAwakeMode: Codable, Equatable, Sendable {
    case off
    case manual
    case timer(until: Date)
    case whileAgentsWork
    case whileAppsRunning
}

struct KeepAwakeConfig: Codable, Equatable, Sendable {
    var allowDisplaySleep: Bool
    var closedLidMode: Bool
    var graceSeconds: TimeInterval
    var batteryFloorPercent: Int
    var acPowerOnlyForClosedLid: Bool
    var watchedBundleIDs: [String]
    var autoOffOnUnlock: Bool
    var reminderAfterIdleSeconds: TimeInterval

    init(
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
            allowDisplaySleep: try container.decode(Bool.self, forKey: .allowDisplaySleep),
            closedLidMode: try container.decode(Bool.self, forKey: .closedLidMode),
            graceSeconds: try container.decode(TimeInterval.self, forKey: .graceSeconds),
            batteryFloorPercent: try container.decode(Int.self, forKey: .batteryFloorPercent),
            acPowerOnlyForClosedLid: try container.decode(Bool.self, forKey: .acPowerOnlyForClosedLid),
            watchedBundleIDs: try container.decode([String].self, forKey: .watchedBundleIDs),
            autoOffOnUnlock: try container.decode(Bool.self, forKey: .autoOffOnUnlock),
            reminderAfterIdleSeconds: try container.decode(
                TimeInterval.self,
                forKey: .reminderAfterIdleSeconds
            )
        )
    }
}
