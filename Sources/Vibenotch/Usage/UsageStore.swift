import Foundation
import Observation

/// Holds what the quota tab shows, and decides when to go and get it.
///
/// Deliberately NOT on the ten-second poll the rest of the app runs on. These
/// are undocumented endpoints on somebody else's servers, and a menu-bar app
/// hammering them every ten seconds is how a tool gets itself rate-limited for
/// asking about rate limits. It refreshes when the tab is opened and then only
/// if what it holds has gone stale.
@Observable
@MainActor
final class UsageStore {
    /// One provider's last known answer, whichever kind it was.
    enum Entry: Sendable, Equatable {
        case loading
        case loaded(UsageSnapshot)
        case failed(UsageUnavailable)
    }

    private(set) var entries: [UsageProviderKind: Entry] = [:]
    private(set) var lastRefresh: Date?

    /// Long enough that opening and closing the panel a few times costs one
    /// request, short enough that a number you act on is not from last hour.
    static let staleAfter: TimeInterval = 120

    private let fetchers: [any UsageFetching]
    private let paceEngine = UsagePaceEngine()
    private var inFlight: Task<Void, Never>?

    init(fetchers: [any UsageFetching] = [ClaudeUsageFetcher(), CodexUsageFetcher()]) {
        self.fetchers = fetchers
    }

    /// Pace for every window of a snapshot, keyed the way the card wants it.
    func pace(for snapshot: UsageSnapshot, now: Date = .now) -> [String: UsagePace] {
        var result: [String: UsagePace] = [:]
        for window in snapshot.windows {
            if let pace = paceEngine.pace(for: window, now: now) {
                result[window.id] = pace
            }
        }
        return result
    }

    /// Called when the quota tab becomes visible. Cheap to call repeatedly.
    func refreshIfStale(now: Date = .now) {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < Self.staleAfter, inFlight == nil {
            return
        }
        refresh(now: now)
    }

    func refresh(now: Date = .now) {
        // One refresh at a time. Two overlapping passes would race to write
        // the same entries and the loser's answer would win at random.
        guard inFlight == nil else { return }

        for fetcher in fetchers where entries[fetcher.kind] == nil {
            entries[fetcher.kind] = .loading
        }

        inFlight = Task { [weak self, fetchers] in
            // Concurrently: two independent hosts, and the slower one should
            // not decide when the faster one appears.
            await withTaskGroup(of: (UsageProviderKind, Entry).self) { group in
                for fetcher in fetchers {
                    group.addTask {
                        do {
                            return (fetcher.kind, .loaded(try await fetcher.fetch(now: now)))
                        } catch let error as UsageUnavailable {
                            return (fetcher.kind, .failed(error))
                        } catch {
                            return (fetcher.kind, .failed(.network(error.localizedDescription)))
                        }
                    }
                }
                for await (kind, entry) in group {
                    await self?.apply(entry, for: kind)
                }
            }
            await self?.finish(at: now)
        }
    }

    private func apply(_ entry: Entry, for kind: UsageProviderKind) {
        // A provider that failed this time keeps its last good numbers rather
        // than blanking: a dropped request is not evidence the quota changed.
        if case .failed = entry, case .loaded = entries[kind] {
            return
        }
        entries[kind] = entry
    }

    private func finish(at now: Date) {
        lastRefresh = now
        inFlight = nil
    }
}
