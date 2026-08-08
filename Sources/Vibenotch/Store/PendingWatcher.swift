import Darwin
import Foundation

final class PendingWatcher: @unchecked Sendable {
    private let pendingURL: URL
    private let fileManager: FileManager
    private let onRescan: @MainActor @Sendable ([PendingApproval]) -> Void
    private let ioQueue = DispatchQueue(label: "com.vibenotch.pending-watcher", qos: .utility)

    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var reopenWorkItem: DispatchWorkItem?
    private var approvalsByID: [String: PendingApproval] = [:]
    private var isRunning = false
    private var reopenDelay: TimeInterval = 0.25

    init(
        pendingURL: URL,
        fileManager: FileManager = .default,
        onRescan: @escaping @MainActor @Sendable ([PendingApproval]) -> Void
    ) {
        self.pendingURL = pendingURL
        self.fileManager = fileManager
        self.onRescan = onRescan
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
                at: pendingURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } catch {
            scheduleReopen()
            return
        }

        let fileDescriptor: Int32 = pendingURL.withUnsafeFileSystemRepresentation { path in
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
                at: pendingURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            closeDirectorySource()
            scheduleReopen()
            return
        }

        var next: [String: PendingApproval] = [:]
        var failedIDs = Set<String>()
        let decoder = JSONDecoder()

        for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let approval = try? decoder.decode(PendingApproval.self, from: data),
                  !approval.sessionId.isEmpty,
                  approval.sessionId != ".",
                  approval.sessionId != "..",
                  !approval.sessionId.contains("/")
            else {
                failedIDs.insert(fileURL.deletingPathExtension().lastPathComponent)
                continue
            }
            next[approval.sessionId] = approval
        }

        for failedID in failedIDs {
            if let existing = approvalsByID[failedID] {
                next[failedID] = existing
            }
        }

        approvalsByID = next
        let approvals = Array(next.values)
        Task { @MainActor [onRescan = onRescan] in
            onRescan(approvals)
        }

        if !failedIDs.isEmpty {
            scheduleRescan(after: 0.5)
        }
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
