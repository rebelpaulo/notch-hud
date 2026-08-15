import CryptoKit
import Foundation

/// Tokens for one model on one day, broken down by how they are priced.
///
/// `cachedInputTokens` is the cache-*read* portion; `inputTokens` is
/// everything else. Kept split even though nothing prices them today: the two
/// are what the logs report, and collapsing them here would throw away the
/// only place the distinction still exists.
///
/// Codex counts its cached tokens INSIDE `input_tokens`; Claude reports them
/// alongside. Reading both the same way inflates one of them silently.
private struct TokenTally: Sendable, Equatable, Codable {
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0

    var totalTokens: Int { inputTokens + cachedInputTokens + outputTokens }

    static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        TokenTally(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

/// One provider's token total on one calendar day.
///
/// Tokens only, no money. Both accounts here are subscriptions, so no
/// per-token charge exists to report — a dollar figure would have to be
/// invented from published API rates and then labelled as something the user
/// did not pay. Tokens are the exact, checkable quantity.
struct LocalUsageDayPoint: Sendable, Equatable, Identifiable {
    let day: Date
    let provider: UsageProviderKind
    let totalTokens: Int
    /// The model that accounted for the most tokens this day, or nil if no
    /// record that day carried a model id.
    let topModel: String?

    var id: String { "\(provider.rawValue)-\(Int(day.timeIntervalSince1970))" }
}

/// Tokens summed over a span of days.
struct LocalUsageTotals: Sendable, Equatable {
    let totalTokens: Int

    static let zero = LocalUsageTotals(totalTokens: 0)

    static func + (lhs: LocalUsageTotals, rhs: LocalUsageTotals) -> LocalUsageTotals {
        LocalUsageTotals(totalTokens: lhs.totalTokens + rhs.totalTokens)
    }
}

/// A full local-usage scan: the daily series plus the two rollups the notch
/// actually displays.
struct LocalUsageSeries: Sendable, Equatable {
    let points: [LocalUsageDayPoint]
    let today: LocalUsageTotals
    /// Rolling 31-day window ending today (today included), not the 31 days
    /// strictly before today — "trailing" here means "the last 31 days of
    /// activity," the window a usage chart would actually draw.
    let trailingThirtyOneDays: LocalUsageTotals
}

/// Parse counts from the most recent `scan(now:)`, kept only so tests can
/// observe the file cache actually skipping unmodified files and resuming
/// appended ones. `bytesRead` is the read-file-position work actually done —
/// zero for a cache hit, the full size for a fresh parse, and just the
/// appended tail for a resumed one.
struct LocalUsageScanStats: Sendable, Equatable {
    let filesParsed: Int
    let filesCached: Int
    let bytesRead: Int
    /// Lines longer than `LocalUsageScanner.maxLineBytes`, skipped rather
    /// than buffered whole. Zero on a normal machine; a nonzero count means
    /// some record's tokens were never counted, which is why this is a
    /// visible stat rather than a silent drop.
    let oversizedLinesSkipped: Int
    /// Cache entries dropped this scan because their path was neither seen
    /// on disk nor still inside the lookback window (see `pruneCache`).
    let filesPruned: Int
}

/// Reads the session logs Claude Code and Codex already write to disk and
/// turns them into a daily token/cost series. No network, no auth — the same
/// files the CLIs themselves read.
///
/// Never reads prompt or response text: only the numeric usage fields and the
/// handful of metadata fields (model id, message/request id, timestamp) named
/// below are ever pulled out of a parsed line.
///
/// An `actor` rather than a plain struct so a caller on the main actor can
/// `await scanner.scan()` without blocking the UI while hundreds of files are
/// statted and read — the actor's own executor absorbs that work.
actor LocalUsageScanner {
    /// Files older than this (by modification date) are skipped without being
    /// opened. 31 days covers the trailing-31-day total; the extra few days
    /// are slack for a session whose last write landed a little before a UTC
    /// day boundary that local time puts on "yesterday."
    static let lookbackDays = 35

    /// Hard ceiling on files read per provider per scan, most-recently-modified
    /// first. On this machine there are ~810 Claude transcripts and ~290 Codex
    /// rollouts total, but `lookbackDays` alone already prunes that to the
    /// files that matter; this is a backstop against a clock skew or a
    /// pathological number of same-day files turning one scan into thousands
    /// of opens.
    static let maxFilesPerProvider = 1500

    /// Lines read *per pass* before giving up on a file — not per file over
    /// its lifetime. Because scans resume from a cached byte offset (see
    /// `CachedFile`), this cap only ever bounds how much of one file's
    /// *appended* tail a single scan will chew through; a long-lived session
    /// that outgrows it just finishes catching up over a few more scans
    /// instead of being silently frozen at whatever it had on the day it
    /// crossed the limit. The largest real rollout seen on this machine is
    /// ~49,800 lines (1.2 GB) in total, so this leaves 2x headroom for how
    /// much a single busy session appends between two polls.
    static let maxLinesPerFile = 100_000

    /// Hard ceiling on how large a single JSONL line may grow before it is
    /// abandoned instead of buffered to the end. Every legitimate
    /// usage-bearing line is a few KB at most (it is metadata, not
    /// conversation content); this exists only to stop a single giant
    /// prompt or tool-result line — real rollouts on this machine reach
    /// 664 MB and a lone record can be a sizeable fraction of that — from
    /// being retained in full (the raw buffer, then the decoded `String`,
    /// then the parsed JSON object, all alive at once).
    static let maxLineBytes = 4 * 1024 * 1024

    /// Bytes at the start of a file hashed to confirm a cached resume point
    /// still refers to the same file lineage, not a same-path replacement.
    /// Deliberately not the modification date: a replacement file can carry
    /// any mtime a rename or `cp -p` gives it, so mtime alone proves nothing
    /// about content.
    static let fingerprintByteCount = 512

    /// Bumped whenever `CachedFile`'s or `TokenTally`'s shape changes. Baked
    /// into the cache file's name rather than checked as a field inside it:
    /// a version bump just makes old cache files invisible (a fresh name
    /// `FileManager` has never seen), so there is no decode-then-compare path
    /// that could misread an old shape instead of just skipping it.
    static let cacheSchemaVersion = 2

    private let claudeProjectsURL: URL
    private let codexRootURLs: [URL]
    private let cacheFileURL: URL
    private var cache: [String: CachedFile] = [:]
    private(set) var lastScanStats = LocalUsageScanStats(filesParsed: 0, filesCached: 0, bytesRead: 0, oversizedLinesSkipped: 0, filesPruned: 0)

    /// Everything needed to resume an append-only log without re-reading the
    /// bytes already accounted for. `Codable` so the whole cache can be
    /// persisted to disk between launches — see `cacheFileURL`.
    private struct CachedFile: Codable {
        let modificationDate: Date
        let size: Int
        /// Byte offset of the start of the first *incomplete* line — i.e.
        /// everything before this offset ends in a newline and has already
        /// been folded into `perDay`. Resuming seeks straight here.
        let byteOffset: Int
        // day -> model id -> tally, so pricing-table edits never invalidate
        // the cache — only file content does.
        let perDay: [Date: [String: TokenTally]]
        /// Claude only: (message id, request id) pairs already counted, kept
        /// across resumes so a duplicate that gets appended later (a resumed
        /// CLI session replaying an earlier message) is still caught even
        /// though the original occurrence is now behind `byteOffset` and
        /// will never be read again.
        let dedupeKeys: Set<String>
        /// Codex only: the model from the most recent `turn_context` seen,
        /// carried across resumes because a resume can start reading well
        /// past the `turn_context` line that introduced it.
        let lastKnownModel: String
        /// SHA-256 of the file's first `fingerprintByteCount` bytes at the
        /// time this entry was written. A same-path replacement that is the
        /// same size or larger looks identical to an append by every other
        /// signal here (size didn't shrink); this is what actually tells
        /// the two apart before any bytes get merged.
        let headFingerprint: Data
    }

    /// `claudeHomeURL`, `codexHomeURL`, and `cacheDirectoryURL` are injectable
    /// so tests never touch the real `~/.claude`, `~/.codex`, or
    /// `~/Library/Caches`. `codexHomeURL` defaults to the `CODEX_HOME`
    /// environment variable when set, matching the Codex CLI's own
    /// resolution.
    ///
    /// The on-disk cache is loaded synchronously here: it is one small JSON
    /// read (metadata and tallies, never conversation text), the same kind of
    /// blocking file call `ClaudeConversationIndex` makes, and every scan
    /// after this one depends on it being in memory already. A missing,
    /// corrupt, or unreadable file is not an error — `cache` just stays
    /// empty and the first `scan()` does a full rescan, exactly as if
    /// Vibenotch had never run before.
    init(
        claudeHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexHomeURL: URL = LocalUsageScanner.defaultCodexHomeURL(),
        cacheDirectoryURL: URL = LocalUsageScanner.defaultCacheDirectoryURL()
    ) {
        claudeProjectsURL = claudeHomeURL.appendingPathComponent(".claude/projects", isDirectory: true)
        codexRootURLs = [
            codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        cacheFileURL = cacheDirectoryURL
            .appendingPathComponent("local-usage-scan-cache.v\(Self.cacheSchemaVersion).json", isDirectory: false)

        if let data = try? Data(contentsOf: cacheFileURL),
           let loaded = try? JSONDecoder().decode([String: CachedFile].self, from: data) {
            cache = loaded
        }
    }

    static func defaultCodexHomeURL() -> URL {
        let env = ProcessInfo.processInfo.environment["CODEX_HOME"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// This is derived data — every byte of it can be rebuilt from the CLIs'
    /// own logs — so it belongs under Caches, not Application Support.
    static func defaultCacheDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.rebelpaulo.vibenotch", isDirectory: true)
    }

    /// `FileManager.default`: this runs off the main actor, and Apple
    /// documents the shared instance as safe for concurrent read-only calls —
    /// same reasoning `ClaudeConversationIndex` uses.
    private var fileManager: FileManager { .default }

    func scan(now: Date = Date()) -> LocalUsageSeries {
        var parsed = 0
        var cached = 0
        var bytesRead = 0
        var oversizedLinesSkipped = 0
        var seenPaths: Set<String> = []

        let claudeDays = scanProvider(
            .claude, roots: [claudeProjectsURL], now: now,
            parsed: &parsed, cached: &cached, bytesRead: &bytesRead,
            oversizedLinesSkipped: &oversizedLinesSkipped, seenPaths: &seenPaths
        )
        let codexDays = scanProvider(
            .codex, roots: codexRootURLs, now: now,
            parsed: &parsed, cached: &cached, bytesRead: &bytesRead,
            oversizedLinesSkipped: &oversizedLinesSkipped, seenPaths: &seenPaths
        )

        let pruned = pruneCache(keeping: seenPaths)

        lastScanStats = LocalUsageScanStats(
            filesParsed: parsed, filesCached: cached, bytesRead: bytesRead,
            oversizedLinesSkipped: oversizedLinesSkipped, filesPruned: pruned
        )
        // Only write when something actually changed `cache` — most polls on
        // a quiet machine are all cache hits, and re-writing an unchanged
        // multi-hundred-file cache to disk on every poll would just trade
        // the I/O this whole cache exists to avoid for a different flavor
        // of it. Pruning counts as a change too, or a deleted/aged-out
        // file's entry would survive on disk forever even though it is
        // gone from the in-memory cache the moment this scan returns.
        if parsed > 0 || pruned > 0 { persistCache() }

        var points: [LocalUsageDayPoint] = []
        points.append(contentsOf: claudeDays.map { day, models in Self.point(day: day, provider: .claude, models: models) })
        points.append(contentsOf: codexDays.map { day, models in Self.point(day: day, provider: .codex, models: models) })
        points.sort { $0.day == $1.day ? $0.provider.rawValue < $1.provider.rawValue : $0.day < $1.day }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let trailingStart = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday

        let today = points
            .filter { $0.day == startOfToday }
            .reduce(LocalUsageTotals.zero) { $0 + $1.totals }
        let trailing = points
            .filter { $0.day >= trailingStart && $0.day <= startOfToday }
            .reduce(LocalUsageTotals.zero) { $0 + $1.totals }

        return LocalUsageSeries(points: points, today: today, trailingThirtyOneDays: trailing)
    }

    private static func point(day: Date, provider: UsageProviderKind, models: [String: TokenTally]) -> LocalUsageDayPoint {
        var totalTokens = 0
        var bestModel: String?
        var bestTokens = -1

        for (model, tally) in models.sorted(by: { $0.key < $1.key }) {
            totalTokens += tally.totalTokens
            if tally.totalTokens > bestTokens {
                bestTokens = tally.totalTokens
                bestModel = model
            }
        }

        return LocalUsageDayPoint(
            day: day,
            provider: provider,
            totalTokens: totalTokens,
            topModel: bestModel == Self.unknownModelKey ? nil : bestModel
        )
    }

    /// Best-effort write of the whole in-memory cache to `cacheFileURL`.
    /// Failure here (a full disk, a sandbox permission hiccup) only costs the
    /// next launch a rescan — it is never allowed to throw or crash, so every
    /// step is `try?`.
    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let directory = cacheFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheFileURL, options: .atomic)
    }

    /// Drops cache entries for paths not in `seenPaths` and returns how many
    /// were removed.
    ///
    /// `seenPaths` is deliberately built from every `.jsonl` file that
    /// exists and is still inside `lookbackDays` — *before*
    /// `maxFilesPerProvider` truncates that list down to what actually gets
    /// parsed (see `scanProvider`) — not from "the files this particular
    /// scan happened to touch." A file only drops out of `seenPaths` by
    /// being deleted or by aging past the lookback window, both one-way:
    /// deleted files don't come back, and files only get older, never
    /// younger. If pruning instead followed the capped, parsed-this-scan
    /// list, a file merely bumped below the top-`maxFilesPerProvider` by
    /// mtime churn — which *can* un-bump back in — would get its cache
    /// entry evicted and then need a full rescan the moment it mattered
    /// again: a rescan storm traded for a cache that is prunable a few KB
    /// sooner. Tying pruning to "genuinely gone or genuinely aged out"
    /// avoids that trade; the cost is that a very large backlog (more
    /// distinct files within the window than `maxFilesPerProvider` — not
    /// the case on this machine today) keeps cache entries for files this
    /// scan didn't get around to parsing, which is bounded by the window
    /// anyway and self-corrects once file count drops back under the cap.
    private func pruneCache(keeping seenPaths: Set<String>) -> Int {
        let stale = cache.keys.filter { !seenPaths.contains($0) }
        for key in stale { cache.removeValue(forKey: key) }
        return stale.count
    }

    // MARK: - Directory walking

    private func scanProvider(
        _ provider: UsageProviderKind,
        roots: [URL],
        now: Date,
        parsed: inout Int,
        cached: inout Int,
        bytesRead: inout Int,
        oversizedLinesSkipped: inout Int,
        seenPaths: inout Set<String>
    ) -> [Date: [String: TokenTally]] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.lookbackDays, to: now) ?? .distantPast

        let withinWindow = roots
            .flatMap(transcriptURLs(under:))
            .filter { $0.date >= cutoff }

        // Every file still inside the window counts as "seen" for pruning
        // purposes, even the ones the `maxFilesPerProvider` cap below is
        // about to exclude from actual parsing — see `pruneCache`'s doc
        // comment for why that distinction matters.
        for file in withinWindow { seenPaths.insert(file.url.path) }

        let files = withinWindow
            .sorted { $0.date > $1.date }
            .prefix(Self.maxFilesPerProvider)

        var combined: [Date: [String: TokenTally]] = [:]
        for file in files {
            let perDay = perDayTallies(
                for: file, provider: provider,
                parsed: &parsed, cached: &cached, bytesRead: &bytesRead,
                oversizedLinesSkipped: &oversizedLinesSkipped
            )
            for (day, models) in perDay {
                combined[day, default: [:]].merge(models) { $0 + $1 }
            }
        }
        return combined
    }

    private func transcriptURLs(under root: URL) -> [(url: URL, date: Date, size: Int)] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(URL, Date, Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            results.append((url, date, size))
        }
        return results
    }

    // MARK: - Per-file parsing (cached, append-only resume)

    /// Session logs only ever grow while a CLI is running, so a modified file
    /// almost always means "some lines got appended," not "the file changed
    /// underneath us." Resuming from `byteOffset` instead of re-parsing from
    /// zero is what keeps a poll on a multi-hundred-MB live session cheap —
    /// see the file-level doc comment on `CachedFile.byteOffset` for the
    /// exact boundary it seeks to.
    private func perDayTallies(
        for file: (url: URL, date: Date, size: Int),
        provider: UsageProviderKind,
        parsed: inout Int,
        cached: inout Int,
        bytesRead: inout Int,
        oversizedLinesSkipped: inout Int
    ) -> [Date: [String: TokenTally]] {
        let key = file.url.path

        // A cache entry only ever describes a resume point for a file whose
        // confirmed prefix still matches: same size and mtime aren't enough
        // on their own (a replacement can land on either), and neither is
        // "didn't shrink" (a replacement can be the same size or larger).
        // The fingerprint is what actually distinguishes "this is the same
        // file, further along" from "this is a different file that happens
        // to occupy the same path now" — but it has to be compared over
        // exactly as many bytes as were fingerprinted when the entry was
        // written (capped at `fingerprintByteCount`), not a fresh 512 bytes
        // of whatever the file looks like today: a file shorter than 512
        // bytes that later grows past that cap would otherwise have its own
        // legitimate append rejected, because the "first 512 bytes" window
        // would newly include appended content that wasn't there — and
        // wasn't hashed — the first time.
        let resumable = cache[key].flatMap { entry -> CachedFile? in
            guard file.size >= entry.byteOffset else { return nil }
            let checkedBytes = min(Self.fingerprintByteCount, entry.byteOffset)
            guard Self.headFingerprint(of: file.url, byteCount: checkedBytes) == entry.headFingerprint else { return nil }
            return entry
        }

        // A full cache hit additionally requires that the *previous* pass
        // actually reached the end of the file — a pass that stopped short
        // (the `maxLinesPerFile` cap, or a read failure) leaves `byteOffset
        // < size`, and such a file must still be resumed even though
        // nothing about it changed since.
        if let resumable, resumable.size == file.size, resumable.modificationDate == file.date,
           resumable.byteOffset == file.size {
            cached += 1
            return resumable.perDay
        }

        let startOffset = resumable?.byteOffset ?? 0

        parsed += 1
        let result = provider == .claude
            ? parseClaudeFile(
                file.url,
                startOffset: startOffset,
                seenMessageKeys: resumable?.dedupeKeys ?? []
            )
            : parseCodexFile(
                file.url,
                startOffset: startOffset,
                seedModel: resumable?.lastKnownModel ?? Self.unknownModelKey
            )
        bytesRead += result.offset - startOffset
        oversizedLinesSkipped += result.skippedOversizedLineCount

        var merged = resumable?.perDay ?? [:]
        for (day, models) in result.perDay {
            merged[day, default: [:]].merge(models) { $0 + $1 }
        }

        let storedFingerprintBytes = min(Self.fingerprintByteCount, result.offset)
        cache[key] = CachedFile(
            modificationDate: file.date,
            size: file.size,
            byteOffset: result.offset,
            perDay: merged,
            dedupeKeys: result.dedupeKeys,
            lastKnownModel: result.lastKnownModel,
            headFingerprint: Self.headFingerprint(of: file.url, byteCount: storedFingerprintBytes)
        )
        return merged
    }

    /// SHA-256 of the file's first `byteCount` bytes — always called with
    /// either `fingerprintByteCount` or, when the file (or the previously
    /// confirmed prefix of it) is shorter than that, the smaller true
    /// length, so the same call with the same `byteCount` reproduces the
    /// same hash for an untouched prefix regardless of how much the file has
    /// grown since. An unreadable file (permissions, mid-delete race)
    /// fingerprints as the hash of empty data — indistinguishable from a
    /// genuinely empty file, but harmless: either way nothing gets resumed
    /// against content that was never actually confirmed, and the next scan
    /// just tries again.
    private static func headFingerprint(of url: URL, byteCount: Int) -> Data {
        guard byteCount > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return Data(SHA256.hash(data: Data()))
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: byteCount)) ?? Data()
        return Data(SHA256.hash(data: head))
    }

    /// Sentinel for "this record carried no model id at all." Kept distinct
    /// from an unrecognised-but-present model id so a caller can tell "we
    /// don't know which model" from "we know the model but not its price."
    private static let unknownModelKey = "\u{0}unknown"

    private struct ParseResult {
        var perDay: [Date: [String: TokenTally]] = [:]
        var offset: Int
        var dedupeKeys: Set<String> = []
        var lastKnownModel: String = LocalUsageScanner.unknownModelKey
        var skippedOversizedLineCount: Int = 0
    }

    /// A line can only produce tokens if the JSON decode below finds
    /// `object["message"]["usage"]`, and Claude's transcripts never escape or
    /// rename that key — every line with a usage object contains the literal
    /// bytes `"usage"`, so rejecting lines without it can never reject one
    /// that would have counted.
    private static let usageMarker: [UInt8] = Array("\"usage\"".utf8)

    private func parseClaudeFile(_ url: URL, startOffset: Int, seenMessageKeys: Set<String>) -> ParseResult {
        var perDay: [Date: [String: TokenTally]] = [:]
        var seen = seenMessageKeys
        let calendar = Calendar.current

        let (endOffset, skippedOversized) = forEachLine(
            in: url,
            startOffset: startOffset,
            limit: Self.maxLinesPerFile,
            prefilter: { Self.containsMarker(Self.usageMarker, in: $0) }
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestampString = object["timestamp"] as? String,
                  let timestamp = Self.parseTimestamp(timestampString)
            else { return }

            // Dedupe only when both ids are present, per the ticket: a resumed
            // session can replay the same assistant message, and only this
            // pair reliably identifies "the same message" rather than "the
            // same content." `seen` is seeded from the cache, so a replay
            // appended after our last scan is still caught even though the
            // original occurrence is now behind `startOffset`.
            if let messageId = message["id"] as? String,
               let requestId = object["requestId"] as? String {
                let dedupeKey = "\(messageId)|\(requestId)"
                if seen.contains(dedupeKey) { return }
                seen.insert(dedupeKey)
            }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let model = (message["model"] as? String) ?? Self.unknownModelKey

            let tally = TokenTally(
                inputTokens: input + cacheCreation,
                cachedInputTokens: cacheRead,
                outputTokens: output
            )
            let day = calendar.startOfDay(for: timestamp)
            let existing = perDay[day]?[model] ?? TokenTally()
            perDay[day, default: [:]][model] = existing + tally
        }
        return ParseResult(perDay: perDay, offset: endOffset, dedupeKeys: seen, skippedOversizedLineCount: skippedOversized)
    }

    /// Codex's `event_msg` `token_count` events carry `last_token_usage`,
    /// which is already the delta since the previous such event in the same
    /// session — not a running total — so no dedupe is needed here the way
    /// Claude's replayed messages need it. Confirmed by inspecting real files
    /// under `~/.codex/sessions` on this machine: consecutive events' totals
    /// differ by exactly the next event's `last_token_usage.total_tokens`.
    ///
    /// `cached_input_tokens` there is a *subset* of `input_tokens` (unlike
    /// Claude, where cache fields are additive) — confirmed the same way:
    /// `input_tokens + output_tokens == total_tokens` in every sampled event.
    /// `reasoning_output_tokens` is likewise already folded into
    /// `output_tokens`, not a separate bucket.
    /// A line can only produce tokens if it is a `token_count` event, and the
    /// model those tokens get attributed to only ever changes on a
    /// `turn_context` line — both are literal `"type"` values in Codex's
    /// rollouts, never escaped, so rejecting lines with neither substring can
    /// never reject one that would have counted or one that carries a model.
    private static let tokenCountMarker: [UInt8] = Array("token_count".utf8)
    private static let turnContextMarker: [UInt8] = Array("turn_context".utf8)

    private func parseCodexFile(_ url: URL, startOffset: Int, seedModel: String) -> ParseResult {
        var perDay: [Date: [String: TokenTally]] = [:]
        var currentModel = seedModel
        let calendar = Calendar.current

        let (endOffset, skippedOversized) = forEachLine(
            in: url,
            startOffset: startOffset,
            limit: Self.maxLinesPerFile,
            prefilter: {
                Self.containsMarker(Self.tokenCountMarker, in: $0) || Self.containsMarker(Self.turnContextMarker, in: $0)
            }
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { return }

            if type == "turn_context", let model = payload["model"] as? String {
                currentModel = model
                return
            }

            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any],
                  let timestampString = object["timestamp"] as? String,
                  let timestamp = Self.parseTimestamp(timestampString)
            else { return }

            let input = (last["input_tokens"] as? Int) ?? 0
            let cachedInput = (last["cached_input_tokens"] as? Int) ?? 0
            let output = (last["output_tokens"] as? Int) ?? 0

            let tally = TokenTally(
                inputTokens: max(0, input - cachedInput),
                cachedInputTokens: cachedInput,
                outputTokens: output
            )
            let day = calendar.startOfDay(for: timestamp)
            let existing = perDay[day]?[currentModel] ?? TokenTally()
            perDay[day, default: [:]][currentModel] = existing + tally
        }
        return ParseResult(perDay: perDay, offset: endOffset, lastKnownModel: currentModel, skippedOversizedLineCount: skippedOversized)
    }

    // `nonisolated(unsafe)`: these are only ever touched from this actor's
    // own serial executor (one caller at a time), so the formatters — which
    // are not Sendable but are safe under single-threaded access — never see
    // concurrent use in practice.
    nonisolated(unsafe) private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ string: String) -> Date? {
        isoFormatterWithFraction.date(from: string) ?? isoFormatter.date(from: string)
    }

    /// Plain byte-for-byte substring search over a raw line, used by every
    /// `prefilter`. `Data.range(of:)` measured far slower here than this loop
    /// — Foundation's implementation bridges through `NSData` per call, which
    /// dominates when it runs on every one of ~430,000 lines rather than the
    /// tiny minority that actually match. `marker` is always under 16 bytes,
    /// so the naive nested loop (no Boyer-Moore skip table) is the right
    /// amount of code for the amount of win.
    private static func containsMarker(_ marker: [UInt8], in data: Data) -> Bool {
        let markerCount = marker.count
        let dataCount = data.count
        guard markerCount > 0, dataCount >= markerCount else { return false }

        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let lastStart = dataCount - markerCount
            var i = 0
            while i <= lastStart {
                var j = 0
                while j < markerCount, bytes[i + j] == marker[j] { j += 1 }
                if j == markerCount { return true }
                i += 1
            }
            return false
        }
    }

    /// Streams `url` in fixed-size chunks starting at `startOffset`, calling
    /// `body` once per complete line that passes `prefilter`, up to `limit`
    /// matching lines, without ever holding the whole file in memory — the
    /// largest real transcript on this machine is over a gigabyte and still
    /// growing every session.
    ///
    /// `prefilter` runs on the raw line bytes *before* `body` gets a decoded
    /// `String`, let alone a parsed JSON object — on real Codex rollouts,
    /// where the average line is ~7 KB of conversation and only a sliver of
    /// lines carry token counts, JSON-decoding every line was the entire
    /// cost of a scan (measured: 186 s of parsing over logs `wc -l` reads in
    /// 4.4 s). `prefilter` MUST be a superset test — it is only safe to skip
    /// `body` for a line `prefilter` rejects if no line that would make
    /// `body` count tokens is ever rejected by it. See the call sites for why
    /// each one holds.
    ///
    /// Returns the byte offset immediately after the last complete line
    /// consumed (matched or not — `limit` counts lines examined, not lines
    /// that matched, so a run of skipped lines can't stall progress). A
    /// trailing partial line (the writer mid-`write()` at the moment we
    /// stopped) is deliberately left unread and off the returned offset, so
    /// the next scan picks it up whole instead of double-counting or
    /// silently dropping half a JSON object.
    private func forEachLine(
        in url: URL,
        startOffset: Int,
        limit: Int,
        prefilter: (Data) -> Bool,
        _ body: (Substring) -> Void
    ) -> (offset: Int, skippedOversizedLineCount: Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (startOffset, 0) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(startOffset))) != nil else { return (startOffset, 0) }

        let newline = UInt8(ascii: "\n")
        var carry = Data()
        var linesProcessed = 0
        var offset = startOffset
        var skippedOversizedLineCount = 0
        // Once the line in progress has grown past `maxLineBytes` with no
        // newline in sight, its bytes are abandoned instead of buffered
        // further: later chunks are searched for that line's terminating
        // newline directly and never appended to `carry`, so the buffer
        // never holds more than about one chunk of an oversized line at a
        // time. `pendingSkipBytes` counts how much of the still-unterminated
        // line has gone by, but is only folded into `offset` once the
        // newline actually turns up — if the file ends first (the writer is
        // still mid-record), nothing here is committed, the same way an
        // ordinary partial trailing line is left whole for the next scan.
        var skippingOversizedLine = false
        var pendingSkipBytes = 0
        let chunkSize = 1 << 20 // 1 MB

        while linesProcessed < limit {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }

            if skippingOversizedLine {
                guard let newlineIndex = chunk.firstIndex(of: newline) else {
                    pendingSkipBytes += chunk.count
                    continue
                }
                pendingSkipBytes += chunk.distance(from: chunk.startIndex, to: newlineIndex) + 1
                offset += pendingSkipBytes
                linesProcessed += 1
                skippedOversizedLineCount += 1
                skippingOversizedLine = false
                pendingSkipBytes = 0
                carry = Data(chunk[chunk.index(after: newlineIndex)...])
            } else {
                carry.append(chunk)
            }

            // Walk a cursor across `carry` and drop the consumed prefix once
            // per chunk, not once per line: `Data.removeSubrange` from the
            // front is O(bytes remaining), and at ~140 lines/chunk (7 KB
            // average line, 1 MB chunk) doing it per line turned into the
            // real bottleneck — quadratic in the chunk size, dwarfing both
            // the prefilter and the JSON decode it protects.
            var consumedThrough = carry.startIndex
            lineLoop: while linesProcessed < limit {
                guard let newlineIndex = carry[consumedThrough...].firstIndex(of: newline) else {
                    let bufferedSoFar = carry.distance(from: consumedThrough, to: carry.endIndex)
                    if bufferedSoFar > Self.maxLineBytes {
                        skippingOversizedLine = true
                        pendingSkipBytes = bufferedSoFar
                        consumedThrough = carry.endIndex
                    }
                    break lineLoop
                }
                let lineData = carry[consumedThrough..<newlineIndex]
                // The cheap raw-byte check runs first; only a survivor pays
                // for UTF-8 decoding.
                if !lineData.isEmpty, prefilter(lineData), let line = String(data: lineData, encoding: .utf8) {
                    body(Substring(line))
                }
                offset += carry.distance(from: consumedThrough, to: newlineIndex) + 1
                linesProcessed += 1
                consumedThrough = carry.index(after: newlineIndex)
            }
            if consumedThrough > carry.startIndex {
                carry.removeSubrange(carry.startIndex..<consumedThrough)
            }
            if skippingOversizedLine {
                carry = Data() // never retain the abandoned line's storage
            }
        }
        return (offset, skippedOversizedLineCount)
    }
}

private extension LocalUsageDayPoint {
    var totals: LocalUsageTotals {
        LocalUsageTotals(totalTokens: totalTokens)
    }
}
