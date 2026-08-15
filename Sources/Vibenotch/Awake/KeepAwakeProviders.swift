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

/// How hard the Mac is struggling to stay cool, as macOS itself judges it.
///
/// Worth having because Gotta go! exists to run the machine hard with the lid
/// shut — the one posture where a MacBook dissipates worst, since the exhaust
/// behind the hinge vents into a closed clamshell. Nothing here controls the
/// fans (that is firmware, and no API can reach it); this only reads the
/// verdict so the app can stop asking for more than the Mac can give.
protocol ThermalStateProviding: Sendable {
    var thermalState: ProcessInfo.ThermalState { get }
}

struct SystemThermalStateProvider: ThermalStateProviding {
    var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }
}

extension ProcessInfo.ThermalState {
    /// The wire name. Spelled out rather than sent as the raw Int so the phone
    /// keeps working if Apple ever renumbers the enum.
    var wireName: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
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
