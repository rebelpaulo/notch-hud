import Darwin
import Foundation

@MainActor
final class CodexRolloutPoller {
    private static let sessionIDPrefix = "codex-app-"
    private static let workingAge: TimeInterval = 25
    private static let removalAge: TimeInterval = 15 * 60
    private static let maximumMetadataBytes = 256 * 1024

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
        let rollouts = rolloutDirectories(now: now).flatMap(rollouts(in:))
        var parentRollouts: [String: Rollout] = [:]
        var activeSubagents: [String: Int] = [:]
        var subagentContexts: [String: Rollout] = [:]
        // Dedupe by subagent uuid: a resume can leave one subagent's rollout
        // in both scanned day-dirs, which must not inflate the count.
        var countedSubagentIDs = Set<String>()
        var subagentIDs = Set<String>()

        for rollout in rollouts {
            guard rollout.metadata.originator == "Codex Desktop" else { continue }

            if rollout.metadata.threadSource == "subagent" {
                // Malformed ids must not enter counting/dedupe (parent path
                // validates via sessionID; mirror it here).
                guard let straySessionID = sessionID(for: rollout.metadata.id) else { continue }
                subagentIDs.insert(rollout.metadata.id)
                removeSpoolFile(sessionID: straySessionID)
                guard let parentID = rollout.metadata.parentThreadID,
                      sessionID(for: parentID) != nil
                else { continue }

                if (subagentContexts[parentID]?.modificationDate ?? .distantPast)
                    < rollout.modificationDate {
                    subagentContexts[parentID] = rollout
                }
                guard rollout.age(at: now) < Self.workingAge,
                      countedSubagentIDs.insert(rollout.metadata.id).inserted
                else { continue }
                activeSubagents[parentID, default: 0] += 1
                continue
            }

            guard sessionID(for: rollout.metadata.id) != nil else { continue }
            if (parentRollouts[rollout.metadata.id]?.modificationDate ?? .distantPast)
                < rollout.modificationDate {
                parentRollouts[rollout.metadata.id] = rollout
            }
        }

        for (parentID, rollout) in parentRollouts {
            guard let sessionID = sessionID(for: parentID) else { continue }
            let subagentCount = activeSubagents[parentID, default: 0]
            let age = rollout.age(at: now)
            if age > Self.removalAge, subagentCount == 0 {
                removeSpoolFile(sessionID: sessionID)
                continue
            }

            let updatedAt = subagentCount > 0
                ? max(
                    subagentContexts[parentID]?.modificationDate ?? .distantPast,
                    rollout.modificationDate
                )
                : rollout.modificationDate
            writeSpoolFile(
                sessionID: sessionID,
                cwd: rollout.metadata.cwd,
                status: age < Self.workingAge || subagentCount > 0 ? .working : .done,
                updatedAt: updatedAt,
                toolLine: Self.subagentToolLine(count: subagentCount)
            )
        }

        // Skip parents that are themselves subagents (nesting): their stray
        // entry was just removed above — recreating it every poll would churn.
        for (parentID, context) in subagentContexts
        where parentRollouts[parentID] == nil && !subagentIDs.contains(parentID) {
            guard let sessionID = sessionID(for: parentID),
                  activeSubagents[parentID, default: 0] > 0 || spoolFileExists(sessionID: sessionID)
            else { continue }

            let subagentCount = activeSubagents[parentID, default: 0]
            if context.age(at: now) > Self.removalAge, subagentCount == 0 {
                removeSpoolFile(sessionID: sessionID)
                continue
            }
            writeSpoolFile(
                sessionID: sessionID,
                cwd: context.metadata.cwd,
                status: subagentCount > 0 ? .working : .done,
                updatedAt: context.modificationDate,
                toolLine: Self.subagentToolLine(count: subagentCount)
            )
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

    private func rollouts(in directoryURL: URL) -> [Rollout] {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension.lowercased() == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-"),
                  let metadata = metadata(at: fileURL),
                  let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate
            else { return nil }

            return Rollout(metadata: metadata, modificationDate: modificationDate)
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

        return RolloutMetadata(
            id: id,
            cwd: cwd,
            originator: originator,
            threadSource: payload["thread_source"] as? String,
            parentThreadID: payload["parent_thread_id"] as? String
        )
    }

    private func sessionID(for rolloutID: String) -> String? {
        guard UUID(uuidString: rolloutID) != nil else { return nil }
        return Self.sessionIDPrefix + String(rolloutID.prefix(8))
    }

    private func writeSpoolFile(
        sessionID: String,
        cwd: String,
        status: SessionStatus,
        updatedAt: Date,
        toolLine: String? = nil
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
            if previous.status == status.rawValue,
               previous.updated == updated,
               previous.toolLine == toolLine {
                return
            }
            var envelope: [String: Any] = [
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
            if let toolLine {
                envelope["toolLine"] = toolLine
            }
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
            NSLog("Vibenotch could not update Codex Desktop session %@: %@", sessionID, error.localizedDescription)
        }
    }

    private func existingEnvelope(
        at fileURL: URL,
        sessionID: String
    ) -> (seq: Int, started: String?, status: String?, updated: String?, toolLine: String?) {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["id"] as? String == sessionID
        else { return (0, nil, nil, nil, nil) }

        return (
            object["seq"] as? Int ?? 0,
            object["started"] as? String,
            object["status"] as? String,
            object["updated"] as? String,
            object["toolLine"] as? String
        )
    }

    private func removeSpoolFile(sessionID: String) {
        guard sessionID.hasPrefix(Self.sessionIDPrefix) else { return }
        let fileURL = spoolURL.appendingPathComponent("\(sessionID).json")
        try? fileManager.removeItem(at: fileURL)
    }

    private func spoolFileExists(sessionID: String) -> Bool {
        fileManager.fileExists(
            atPath: spoolURL.appendingPathComponent("\(sessionID).json").path
        )
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func subagentToolLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 subagente a trabalhar"
            : "\(count) subagentes a trabalhar"
    }
}

private struct RolloutMetadata {
    let id: String
    let cwd: String
    let originator: String
    let threadSource: String?
    let parentThreadID: String?
}

private struct Rollout {
    let metadata: RolloutMetadata
    let modificationDate: Date

    func age(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(modificationDate))
    }
}
