import Foundation
import Observation

@MainActor
final class SleepGuardController {
    let isInstalled: Bool

    private let engine: KeepAwakeEngine
    private let scriptURL: URL
    private let commandQueue = DispatchQueue(label: "com.actionable.notchhud.sleepguard")
    private var isObserving = false
    private var lastDesiredState: Bool?

    init(
        engine: KeepAwakeEngine,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.engine = engine
        scriptURL = homeURL.appendingPathComponent(
            ".notch-hud/bin/notch-sleepguard",
            isDirectory: false
        )
        let sudoersExists = FileManager.default.fileExists(atPath: "/etc/sudoers.d/notch-hud")
        isInstalled = FileManager.default.isExecutableFile(atPath: scriptURL.path) && sudoersExists
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        enqueue("off")
        lastDesiredState = false
        observeDesiredState()
    }

    func stop() {
        isObserving = false
        lastDesiredState = false
        enqueue("off")
    }

    /// Starts the defensive reset without waiting on the main thread. The child
    /// process remains able to finish while the application tears down.
    func resetForTermination() {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = ["off"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("NotchHUD não conseguiu repor o sleepguard ao terminar: %@", error.localizedDescription)
        }
    }

    private func observeDesiredState() {
        withObservationTracking {
            _ = engine.wantsClosedLidAwake
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.applyDesiredState()
                self.observeDesiredState()
            }
        }
        applyDesiredState()
    }

    private func applyDesiredState() {
        let desired = engine.wantsClosedLidAwake
        guard lastDesiredState != desired else { return }
        lastDesiredState = desired
        enqueue(desired ? "on" : "off")
    }

    private func enqueue(_ action: String) {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        let scriptPath = scriptURL.path
        commandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.arguments = [action]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NSLog("NotchHUD sleepguard '%@' terminou com estado %d", action, process.terminationStatus)
                }
            } catch {
                NSLog("NotchHUD não conseguiu executar o sleepguard: %@", error.localizedDescription)
            }
        }
    }
}

struct PortugueseKeepAwakeNotificationPoster: NotificationPosting, Sendable {
    private let system = SystemNotificationPoster()

    func post(_ message: String) {
        let localized = switch message {
        case "All-Nighter ended — all agents done":
            "All-Nighter terminou — todos os agentes concluíram"
        default:
            message
        }
        system.post(localized)
    }
}
