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

    /// True only before the first round has come back. Distinguishes "we have
    /// not asked yet" from "we asked and nobody is signed in", which the empty
    /// state has to word differently.
    var isLoading: Bool {
        entries.isEmpty || entries.values.contains { $0 == .loading }
    }

    /// Tokens for one provider, either today or across the trailing window the
    /// card claims to show.
    ///
    /// The window is applied on purpose. The first version filtered by date
    /// only in the `today` case and otherwise summed every point the scanner
    /// returned — and the scanner keeps a few days more than the card labels,
    /// so a long-lived transcript touched recently pulled older days into a
    /// total captioned "Last 31 days". A number under a label that does not
    /// describe it is worse than no number.
    func tokens(for provider: UsageProviderKind, today: Bool, now: Date = .now) -> Int {
        guard let localSeries else { return 0 }
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -(Self.trailingDays - 1), to: calendar.startOfDay(for: now))

        let days = localSeries.points.filter { point in
            guard point.provider == provider else { return false }
            if today { return calendar.isDate(point.day, inSameDayAs: now) }
            guard let cutoff else { return true }
            return point.day >= cutoff
        }
        return days.reduce(0) { $0 + $1.totalTokens }
    }

    /// Matches the caption on the card. Change one and the other is a lie.
    static let trailingDays = 31

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

    /// Called when the quota tab becomes visible, and on a slower cadence by
    /// the remote bridge. Cheap to call repeatedly.
    ///
    /// `maxAge` is a parameter because the two callers want different things:
    /// someone staring at the panel deserves a fresher number than a
    /// background publish does, and the background one is the one that must
    /// not become a poll against an undocumented endpoint.
    func refreshIfStale(maxAge: TimeInterval = staleAfter, now: Date = .now) {
        if let lastRefresh, now.timeIntervalSince(lastRefresh) < maxAge, inFlight == nil {
            return
        }
        refresh(now: now)
    }

    /// How often the bridge refreshes so the PHONE has something to show. The
    /// quota tab is not the only consumer any more, and it was the only
    /// trigger: without this, nothing was ever fetched unless someone opened
    /// the notch on the Mac — which is exactly the trip to the Mac the phone
    /// exists to save.
    static let backgroundMaxAge: TimeInterval = 300

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
        // Logged because a quota that never appears is otherwise indis-
        // tinguishable from one that is simply not published yet: the panel
        // shows nothing either way, by design. Without this the only way to
        // tell a signed-out account from a broken endpoint is a rebuild.
        // The reason only — never the token, never the account.
        if case let .failed(reason) = entry {
            // Plain %@: NSLog does not understand os_log's %{public}@ and
            // prints the specifier verbatim. The unified log redacts this to
            // <private>, so read it by running the binary from a terminal —
            // which is how the publish failure below was actually found.
            NSLog("Vibenotch usage: %@ unavailable (%@)", kind.rawValue, String(describing: reason))
        }

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
