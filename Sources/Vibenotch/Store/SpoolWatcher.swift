import Darwin
import Foundation

final class SpoolWatcher: @unchecked Sendable {
    private let spoolURL: URL
    private let store: SessionStore
    private let fileManager: FileManager
    private let reader = SpoolReader()
    private let ioQueue = DispatchQueue(label: "com.vibenotch.spool-watcher", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var reopenWorkItem: DispatchWorkItem?
    private var sessionsByID: [String: Session] = [:]
    private var isRunning = false
    private var reopenDelay: TimeInterval = 0.25

    init(spoolURL: URL, store: SessionStore, fileManager: FileManager = .default) {
        self.spoolURL = spoolURL
        self.store = store
        self.fileManager = fileManager
    }

    func start() {
        ioQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.openDirectorySource()
        }
    }

    func stop() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.reopenWorkItem?.cancel()
            self.reopenWorkItem = nil
            self.closeDirectorySource()
        }
    }

    private func openDirectorySource() {
        guard isRunning else { return }

        do {
            try fileManager.createDirectory(
                at: spoolURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            scheduleReopen()
            return
        }

        let fileDescriptor: Int32 = spoolURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_EVTONLY)
        }
        guard fileDescriptor >= 0 else {
            scheduleReopen()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: ioQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        source.setCancelHandler {
            _ = Darwin.close(fileDescriptor)
        }

        self.source = source
        reopenDelay = 0.25
        source.resume()
        rescan()
    }

    private func handleDirectoryEvent() {
        guard let source else { return }
        let event = source.data

        if event.contains(.delete) || event.contains(.rename) {
            closeDirectorySource()
            scheduleReopen()
            return
        }

        scheduleRescan(after: 0.15)
    }

    private func scheduleRescan(after delay: TimeInterval) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.rescan()
        }
        debounceWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func rescan() {
        guard isRunning else { return }

        let fileURLs: [URL]
        do {
            fileURLs = try fileManager.contentsOfDirectory(
                at: spoolURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            closeDirectorySource()
            scheduleReopen()
            return
        }

        var scannedSessions: [String: Session] = [:]
        var failedIDs = Set<String>()

        for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "json" {
            guard let session = reader.read(at: fileURL) else {
                failedIDs.insert(fileURL.deletingPathExtension().lastPathComponent)
                continue
            }

            if let scanned = scannedSessions[session.id] {
                if shouldUse(session, insteadOf: scanned) {
                    scannedSessions[session.id] = session
                }
            } else {
                scannedSessions[session.id] = session
            }
        }

        var nextSessions: [String: Session] = [:]
        for (id, session) in scannedSessions {
            if let current = sessionsByID[id], !shouldUse(session, insteadOf: current) {
                nextSessions[id] = current
            } else {
                nextSessions[id] = session
            }
        }

        for id in failedIDs {
            if let current = sessionsByID[id] {
                nextSessions[id] = current
            }
        }

        sessionsByID = nextSessions
        let sessions = Array(nextSessions.values)
        Task { @MainActor [weak store = store] in
            store?.apply(sessions)
        }

        if !failedIDs.isEmpty {
            scheduleRescan(after: 0.5)
        }
    }

    private func shouldUse(_ candidate: Session, insteadOf current: Session) -> Bool {
        if candidate.seq > current.seq {
            return true
        }
        if candidate.seq < current.seq {
            return candidate.updatedAt > current.updatedAt
        }
        return candidate.updatedAt >= current.updatedAt
    }

    private func closeDirectorySource() {
        guard let source else { return }
        self.source = nil
        source.cancel()
    }

    private func scheduleReopen() {
        guard isRunning else { return }

        reopenWorkItem?.cancel()
        let delay = reopenDelay
        reopenDelay = min(reopenDelay * 2, 5)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning else { return }
            self.openDirectorySource()
        }
        reopenWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
