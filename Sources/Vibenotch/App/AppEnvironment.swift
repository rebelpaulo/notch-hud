import Foundation

struct AppEnvironment {
    let rootURL: URL
    let configURL: URL
    let spoolURL: URL
    let pendingURL: URL
    let decisionsURL: URL
    let sessionAllowURL: URL
    let workingStaleSeconds: TimeInterval = 90
    let dropSeconds: TimeInterval = 900

    init(fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        let rootURL = home.appendingPathComponent(".vibenotch", isDirectory: true)
        self.rootURL = rootURL
        configURL = rootURL
            .appendingPathComponent("config.json", isDirectory: false)
        spoolURL = rootURL
            .appendingPathComponent("sessions", isDirectory: true)
        pendingURL = rootURL
            .appendingPathComponent("pending", isDirectory: true)
        decisionsURL = rootURL
            .appendingPathComponent("decisions", isDirectory: true)
        sessionAllowURL = rootURL
            .appendingPathComponent("session-allow", isDirectory: true)

        for directoryURL in [spoolURL, pendingURL, decisionsURL, sessionAllowURL] {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: directoryURL.path
                )
            } catch {
                NSLog(
                    "Vibenotch could not prepare %@: %@",
                    directoryURL.path,
                    error.localizedDescription
                )
            }
        }

        Self.adoptLegacyFiles(
            from: home.appendingPathComponent(".notch-hud", isDirectory: true),
            into: rootURL,
            fileManager: fileManager
        )
    }

    /// The app was called NotchHUD and kept its state in `~/.notch-hud`. On
    /// upgrade those files stay there while the app reads only the new
    /// directory, so the saved Gotta go! config and the phone pairing would
    /// silently revert to defaults. Copy them across once — never overwrite
    /// anything already in the new home, and leave the originals in place so
    /// a downgrade still works.
    ///
    /// ".notch-hud" is a HISTORICAL LITERAL: renaming it would make this
    /// migration read from the directory it writes to.
    private static func adoptLegacyFiles(
        from legacyRoot: URL,
        into rootURL: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }

        for name in ["config.json", "remote.json"] {
            let source = legacyRoot.appendingPathComponent(name, isDirectory: false)
            let target = rootURL.appendingPathComponent(name, isDirectory: false)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: target.path)
            else { continue }

            do {
                try fileManager.copyItem(at: source, to: target)
                NSLog("Vibenotch adopted %@ from the previous install", name)
            } catch {
                NSLog(
                    "Vibenotch could not adopt %@: %@",
                    name,
                    error.localizedDescription
                )
            }
        }
    }
}
