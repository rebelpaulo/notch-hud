import Foundation
import Observation

@MainActor
final class SleepGuardController {
    let isInstalled: Bool

    private let engine: KeepAwakeEngine
    private let scriptURL: URL
    private let commandQueue = DispatchQueue(label: "com.rebelpaulo.vibenotch.sleepguard")
    private var isObserving = false
    private var lastDesiredState: Bool?

    init(
        engine: KeepAwakeEngine,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.engine = engine
        scriptURL = homeURL.appendingPathComponent(
            ".vibenotch/bin/vibenotch-sleepguard",
            isDirectory: false
        )
        let sudoersExists = FileManager.default.fileExists(atPath: "/etc/sudoers.d/vibenotch")
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

    /// Waits for earlier commands, then launches the defensive reset without
    /// waiting for the child process to exit.
    func resetForTermination() {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        isObserving = false
        let scriptPath = scriptURL.path
        commandQueue.sync {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scriptPath)
            process.arguments = ["off"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog(
                    "Vibenotch could not reset the sleepguard on shutdown: %@",
                    error.localizedDescription
                )
            }
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
                    NSLog("Vibenotch sleepguard '%@' terminou com estado %d", action, process.terminationStatus)
                }
            } catch {
                NSLog("Vibenotch could not run the sleepguard: %@", error.localizedDescription)
            }
        }
    }
}
