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
        let rootURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibenotch", isDirectory: true)
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
    }
}
