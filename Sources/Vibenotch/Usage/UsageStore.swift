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

    /// Local token history. Separate from `entries` because it comes from
    /// disk rather than the network and moves on a completely different
    /// timescale — the first walk over gigabytes of logs takes minutes, every
    /// one after it takes a fraction of a second.
    private(set) var localSeries: LocalUsageSeries?
    private(set) var isScanningLocal = false

    private let fetchers: [any UsageFetching]
    private let scanner: LocalUsageScanner
    private let paceEngine = UsagePaceEngine()
    private var inFlight: Task<Void, Never>?
    private var localScan: Task<Void, Never>?

    init(
        fetchers: [any UsageFetching] = [ClaudeUsageFetcher(), CodexUsageFetcher()],
        scanner: LocalUsageScanner = LocalUsageScanner()
    ) {
        self.fetchers = fetchers
        self.scanner = scanner
    }

    func tokens(for provider: UsageProviderKind, today: Bool) -> Int {
        guard let localSeries else { return 0 }
        let days = today
            ? localSeries.points.filter { $0.provider == provider && Calendar.current.isDateInToday($0.day) }
            : localSeries.points.filter { $0.provider == provider }
        return days.reduce(0) { $0 + $1.totalTokens }
    }

    /// Kicked off when the tab opens. The scan is the slow one, so it runs
    /// once per launch and then rides its own on-disk cache.
    func scanLocalIfNeeded() {
        guard localScan == nil, localSeries == nil else { return }
        isScanningLocal = true
        localScan = Task { [weak self, scanner] in
            let series = await scanner.scan()
            await self?.applyLocal(series)
        }
    }

    private func applyLocal(_ series: LocalUsageSeries) {
        localSeries = series
        isScanningLocal = false
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
