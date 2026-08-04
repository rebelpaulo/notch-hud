import Darwin
import Foundation

@MainActor
final class CodexRolloutPoller {
    private static let sessionIDPrefix = "codex-app-"
    private static let workingAge: TimeInterval = 25
    private static let removalAge: TimeInterval = 15 * 60
    private static let maximumMetadataBytes = 64 * 1024

    private let sessionsRootURL: URL
    private let spoolURL: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private var timer: Timer?

    init(
        sessionsRootURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        spoolURL: URL,
        fileManager: FileManager = .default,
        calendar: Calendar = .current
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.spoolURL = spoolURL
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func start() {
        guard timer == nil else { return }

        poll()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs one bounded scan synchronously. Tests call this directly with a fixed date.
    func poll(now: Date = Date()) {
        for directoryURL in rolloutDirectories(now: now) {
            poll(directoryURL: directoryURL, now: now)
        }
    }

    private func rolloutDirectories(now: Date) -> [URL] {
        [now, calendar.date(byAdding: .day, value: -1, to: now)].compactMap { date in
            guard let date else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day
            else { return nil }

            return sessionsRootURL
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        }
    }

    private func poll(directoryURL: URL, now: Date) {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "jsonl"
            && fileURL.lastPathComponent.hasPrefix("rollout-") {
            guard let metadata = metadata(at: fileURL), metadata.originator == "Codex Desktop" else {
                continue
            }

            let sessionID = Self.sessionIDPrefix + String(metadata.id.prefix(8))
            guard sessionID.count > Self.sessionIDPrefix.count,
                  let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate
            else { continue }

            let age = max(0, now.timeIntervalSince(modificationDate))
            if age > Self.removalAge {
                removeSpoolFile(sessionID: sessionID)
                continue
            }

            writeSpoolFile(
                sessionID: sessionID,
                cwd: metadata.cwd,
                status: age < Self.workingAge ? .working : .done,
                updatedAt: modificationDate
            )
        }
    }

    private func metadata(at fileURL: URL) -> RolloutMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: Self.maximumMetadataBytes),
              let newlineIndex = data.firstIndex(of: 0x0A)
        else { return nil }

        let line = data[..<newlineIndex]
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String,
              let originator = payload["originator"] as? String
        else { return nil }

        return RolloutMetadata(id: id, cwd: cwd, originator: originator)
    }

    private func writeSpoolFile(
        sessionID: String,
        cwd: String,
        status: SessionStatus,
        updatedAt: Date
    ) {
        do {
            try fileManager.createDirectory(
                at: spoolURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )

            let destinationURL = spoolURL.appendingPathComponent("\(sessionID).json")
            let previous = existingEnvelope(at: destinationURL, sessionID: sessionID)
            let updated = Self.iso8601String(from: updatedAt)
            // Idle rollouts produce identical envelopes — skip the rewrite so
            // seq stays meaningful and the spool watcher doesn't churn.
            if previous.status == status.rawValue, previous.updated == updated {
                return
            }
            let envelope: [String: Any] = [
                "schema": 1,
                "id": sessionID,
                "agent": "codex",
                "project": URL(fileURLWithPath: cwd).lastPathComponent,
                "cwd": cwd,
                "status": status.rawValue,
                "updated": updated,
                "started": previous.started ?? updated,
                "seq": previous.seq + 1,
                "terminal": [String: String](),
                "source": "codex-desktop"
            ]
            var data = try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]
            )
            data.append(0x0A)

            let temporaryURL = spoolURL.appendingPathComponent(
                ".\(sessionID).\(UUID().uuidString).tmp"
            )
            try data.write(to: temporaryURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: temporaryURL.path
            )
            guard rename(temporaryURL.path, destinationURL.path) == 0 else {
                let renameError = errno
                try? fileManager.removeItem(at: temporaryURL)
                throw POSIXError(POSIXErrorCode(rawValue: renameError) ?? .EIO)
            }
        } catch {
            NSLog("NotchHUD could not update Codex Desktop session %@: %@", sessionID, error.localizedDescription)
        }
    }

    private func existingEnvelope(
        at fileURL: URL,
        sessionID: String
    ) -> (seq: Int, started: String?, status: String?, updated: String?) {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? String == sessionID
        else { return (0, nil, nil, nil) }

        return (
            object["seq"] as? Int ?? 0,
            object["started"] as? String,
            object["status"] as? String,
            object["updated"] as? String
        )
    }

    private func removeSpoolFile(sessionID: String) {
        guard sessionID.hasPrefix(Self.sessionIDPrefix) else { return }
        let fileURL = spoolURL.appendingPathComponent("\(sessionID).json")
        try? fileManager.removeItem(at: fileURL)
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct RolloutMetadata {
    let id: String
    let cwd: String
    let originator: String
}
