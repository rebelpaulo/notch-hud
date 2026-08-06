import AppKit
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

protocol SleepAssertionProviding: Sendable {
    func create(type: String, reason: String) -> IOPMAssertionID?
    func release(id: IOPMAssertionID)
}

struct SystemSleepAssertionProvider: SleepAssertionProviding {
    func create(type: String, reason: String) -> IOPMAssertionID? {
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        return result == kIOReturnSuccess ? assertionID : nil
    }

    func release(id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

protocol RunningApplicationsProviding: Sendable {
    func runningBundleIdentifiers() -> Set<String>
}

struct SystemRunningApplicationsProvider: RunningApplicationsProviding {
    func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

protocol PowerSourceProviding: Sendable {
    var percent: Int? { get }
    var isOnACPower: Bool { get }
    func snapshot() -> PowerSourceSnapshot
}

struct PowerSourceSnapshot: Sendable {
    let percent: Int?
    let isOnACPower: Bool
}

extension PowerSourceProviding {
    func snapshot() -> PowerSourceSnapshot {
        PowerSourceSnapshot(percent: percent, isOnACPower: isOnACPower)
    }
}

struct SystemPowerSourceProvider: PowerSourceProviding {
    private var batteryDescription: [String: Any]? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return values
        }
        return nil
    }

    var percent: Int? {
        snapshot().percent
    }

    var isOnACPower: Bool {
        snapshot().isOnACPower
    }

    func snapshot() -> PowerSourceSnapshot {
        let description = batteryDescription
        let percent: Int?
        if let description,
           let current = description[kIOPSCurrentCapacityKey] as? Int,
           let maximum = description[kIOPSMaxCapacityKey] as? Int,
           maximum > 0 {
            percent = Int((Double(current) / Double(maximum) * 100).rounded())
        } else {
            percent = nil
        }
        return PowerSourceSnapshot(
            percent: percent,
            isOnACPower: Self.isOnACPower(batteryDescription: description)
        )
    }

    static func isOnACPower(batteryDescription: [String: Any]?) -> Bool {
        guard let batteryDescription else {
            return true
        }
        return batteryDescription[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    }
}

protocol NotificationPosting: Sendable {
    func post(_ message: String)
}

struct SystemNotificationPoster: NotificationPosting, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func post(_ message: String) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                addNotification(message)
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted {
                        addNotification(message)
                    }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func addNotification(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = message
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
