import CryptoKit
import Foundation
import Observation

struct CommandRunResult: Sendable {
    let stdout: String
    let exitCode: Int32
}

protocol CommandRunning: Sendable {
    func run(arguments: [String], stdin: String?) async -> CommandRunResult
}

extension CommandRunning {
    func run(arguments: [String]) async -> CommandRunResult {
        await run(arguments: arguments, stdin: nil)
    }
}

struct RemoteScriptCommandRunner: CommandRunning {
    let scriptURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        scriptURL = homeURL.appendingPathComponent(
            ".vibenotch/bin/vibenotch-remote-push",
            isDirectory: false
        )
    }

    func run(arguments: [String], stdin: String? = nil) async -> CommandRunResult {
        await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let input = Pipe()
            process.executableURL = scriptURL
            process.arguments = arguments
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                // ponytail: writes the whole (small, <1KB settings JSON) body
                // before draining stdout; fine at this payload size, would
                // need concurrent read/write pumps if stdin ever got large.
                if let stdin {
                    input.fileHandleForWriting.write(Data(stdin.utf8))
                    try? input.fileHandleForWriting.close()
                }
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                return CommandRunResult(
                    stdout: String(decoding: data, as: UTF8.self),
                    exitCode: process.terminationStatus
                )
            } catch {
                NSLog("Vibenotch could not run vibenotch-remote-push: %@", error.localizedDescription)
                return CommandRunResult(stdout: "", exitCode: 127)
            }
        }.value
    }
}

@MainActor
protocol RemoteKeepAwakeEngine: AnyObject {
    var isActive: Bool { get }
    var isOnACPower: Bool { get }
    var thermalState: ProcessInfo.ThermalState { get }
    var mode: KeepAwakeMode { get }
    var lastOffReason: KeepAwakeOffReason? { get }
    var config: KeepAwakeConfig { get set }
    func setMode(_ newMode: KeepAwakeMode, now: Date)
}

extension KeepAwakeEngine: RemoteKeepAwakeEngine {}

@MainActor
protocol RemoteSessionStoring: AnyObject {
    var sessions: [Session] { get }
}

extension SessionStore: RemoteSessionStoring {}

/// The slice of `UsageStore` the publisher needs: what each provider last
/// loaded, and the pace engine's read on it. Pace is computed here — on the
/// Mac — and never in JavaScript, so this is the only door into that math.
/// `localSeries` and `scanLocalIfNeeded()` are the same door for the local
/// token-history scan the quota tab already triggers — the bridge triggers it
/// too, so the phone gets history even if the notch is never opened.
@MainActor
protocol RemoteUsageStoring: AnyObject {
    var entries: [UsageProviderKind: UsageStore.Entry] { get }
    var localSeries: LocalUsageSeries? { get }
    func pace(for snapshot: UsageSnapshot, now: Date) -> [String: UsagePace]
    func refreshIfStale(maxAge: TimeInterval, now: Date)
    func scanLocalIfNeeded()
}

extension UsageStore: RemoteUsageStoring {}

@MainActor
final class RemoteBridge {
    private static let batteryThresholds = [50, 30, 20]
    private static let lastAppliedSettingsRevKey = "remoteBridge.lastAppliedSettingsRev"
    private static let sessionIDKeyKey = "remoteBridge.sessionIDKey"
    private static let lastPublishedUsageDigestKey = "remoteBridge.lastPublishedUsageDigest"
    private static let lastPublishedUsageHistoryDigestKey = "remoteBridge.lastPublishedUsageHistoryDigest"
    /// Read by the Settings window, which runs the same script from a
    /// different place and would otherwise have no way to know.
    static let scriptMismatchKey = "remoteBridge.scriptMismatch"
    private static let pairedRemoteURLKey = "remoteBridge.pairedRemoteURL"

    private let engine: any RemoteKeepAwakeEngine
    private let sessionStore: any RemoteSessionStoring
    private let usageStore: any RemoteUsageStoring
    private let commandRunner: any CommandRunning
    private let powerSourceProvider: any PowerSourceProviding
    private let pairingURL: URL
    private let userDefaults: UserDefaults
    private let conversationIndex: ClaudeConversationIndex
    private let resumer: any ConversationResuming
    private let remoteControlServer: RemoteControlServer

    private var timer: Timer?
    private var isStarted = false
    private var previousMode: KeepAwakeMode
    private var previousBatteryPercent: Int?
    private var sentBatteryThresholds = Set<Int>()
    private var needsMeSessionIDs = Set<String>()
    // The config snapshot we last know to be in sync with the remote —
    // either just applied from a newer remote rev, or just pushed up.
    // Diverging from it locally is what triggers a --settings-put.
    private var lastSyncedSettingsSnapshot: RemoteSettingsSnapshot

    /// Per-installation, generated once and never published. An UNKEYED digest
    /// would have achieved nothing: anyone holding a candidate id could
    /// recompute it and confirm the match, and Codex terminal sessions are
    /// `codex-<PID>` — a space small enough to enumerate outright.
    private var sessionIDKey: SymmetricKey {
        if let stored = userDefaults.data(forKey: Self.sessionIDKeyKey), stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        userDefaults.set(data, forKey: Self.sessionIDKeyKey)
        return SymmetricKey(data: data)
    }

    private var lastAppliedSettingsRev: Int {
        get { userDefaults.integer(forKey: Self.lastAppliedSettingsRevKey) }
        set { userDefaults.set(newValue, forKey: Self.lastAppliedSettingsRevKey) }
    }

    init(
        engine: any RemoteKeepAwakeEngine,
        sessionStore: any RemoteSessionStoring,
        usageStore: any RemoteUsageStoring = UsageStore(),
        commandRunner: (any CommandRunning)? = nil,
        powerSourceProvider: any PowerSourceProviding = SystemPowerSourceProvider(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        userDefaults: UserDefaults = .standard,
        conversationIndex: ClaudeConversationIndex? = nil,
        resumer: (any ConversationResuming)? = nil,
        remoteControlServer: RemoteControlServer = RemoteControlServer()
    ) {
        self.conversationIndex = conversationIndex ?? ClaudeConversationIndex(homeURL: homeURL)
        self.resumer = resumer ?? TerminalConversationResumer()
        self.remoteControlServer = remoteControlServer
        self.engine = engine
        self.sessionStore = sessionStore
        self.usageStore = usageStore
        self.commandRunner = commandRunner ?? RemoteScriptCommandRunner(homeURL: homeURL)
        self.powerSourceProvider = powerSourceProvider
        self.userDefaults = userDefaults
        pairingURL = homeURL.appendingPathComponent(".vibenotch/remote.json", isDirectory: false)
        previousMode = engine.mode
        lastSyncedSettingsSnapshot = RemoteSettingsSnapshot(engine.config)
        lastPublishedUsageDigest = userDefaults.string(forKey: Self.lastPublishedUsageDigestKey)
        lastPublishedUsageHistoryDigest = userDefaults.string(forKey: Self.lastPublishedUsageHistoryDigestKey)
    }

    func start() {
        // isConfigured is checked per tick, so pairing created after launch
        // starts working within one poll cycle — no restart needed.
        guard !isStarted else { return }
        isStarted = true
        observeChanges()

        // 10s: the phone's own UI refreshes on the same order, so a toggle on
        // either side lands within about ten seconds. One GET per tick (state
        // and settings share /api/state), so this is the same request volume
        // the 45s two-call version had.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkNow(pollRemoteState: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        Task { @MainActor [weak self] in
            await self?.checkNow(pollRemoteState: true)
        }
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    func checkNow(pollRemoteState: Bool = false) async {
        guard isConfigured else { return }

        let currentMode = engine.mode
        let allAgentsFinished = currentMode == .off
            && previousMode == .whileAgentsWork
            && engine.lastOffReason == .whileAgentsWorkGrace

        if engine.isActive {
            await evaluateBattery()
        }

        previousMode = currentMode

        // A local toggle reconciles right away instead of waiting for the next
        // poll tick — observeChanges() calls this the moment the bolt flips, so
        // the phone sees the new state in about a second. It goes through the
        // same reconcile as a timer tick (rather than pushing straight up) so
        // there is exactly one place that decides which side wins.
        let toggledLocally = lastSyncedActive.map { $0 != engine.isActive } ?? false

        if allAgentsFinished {
            await push(
                title: "Vibenotch",
                body: t("All agents finished — Gotta go! turned itself off"),
                tag: "agents-done"
            )
        }

        guard engine.isActive else {
            previousBatteryPercent = nil
            if powerSourceProvider.snapshot().isOnACPower {
                sentBatteryThresholds.removeAll()
            }
            needsMeSessionIDs.removeAll()
            // Settings AND the on/off state must sync while Gotta go! is off:
            // the phone configures the next session, and turning it ON remotely
            // is only reachable from here. (Battery/needs-me pushes stay
            // active-only.)
            if pollRemoteState || toggledLocally {
                await reconcileRemote()
            } else {
                // A session changing is known here the instant it happens.
                // Waiting for the next ten-second tick to say so put the phone
                // up to fifteen seconds behind the Mac, which reads as "it did
                // not update" and gets answered with a manual refresh.
                await publishSessionsIfChanged(remoteCount: nil)
            }
            return
        }

        // Sessions FIRST. evaluateNeedsMeSessions() awaits a push, and that
        // curl allows ten seconds for the transfer — so a slow notification
        // endpoint would put the delay right back where this change removed
        // it from.
        if pollRemoteState || toggledLocally {
            await reconcileRemote()
            await evaluateNeedsMeSessions()
        } else {
            await publishSessionsIfChanged(remoteCount: nil)
            await evaluateNeedsMeSessions()
        }
    }

    // The last battery reading published, so the Mac stops re-sending a number
    // the phone already has. A percent change or a plug/unplug is worth a
    // write; ten identical readings a minute are not.
    private var lastPublishedBattery: PublishedBattery?
    private var lastPublishedThermal: String?
    private var isPublishingMachineState = false
    private var machineStateChangedWhilePublishing = false

    private struct PublishedBattery: Equatable {
        let percent: Int
        let isOnACPower: Bool
    }

    /// The last snapshot published, so an unchanged session list is not
    /// rewritten every tick. Elapsed time is derived on the phone from
    /// `started`, so a ticking clock is not itself a change.
    private var lastPublishedSessions: [PublishedSession]?
    private var lastPublishedResumable: [PublishedConversation]?

    /// A digest survives restarts without retaining account or quota data in
    /// preferences. That survival matters when the new reading is empty: nil
    /// must mean "never published", not merely "this process just launched".
    private var lastPublishedUsageDigest: String?

    /// Same rule as `lastPublishedUsageDigest`, for local token history.
    private var lastPublishedUsageHistoryDigest: String?

    /// The last request actually carried out. A clear that succeeds on the
    /// server but is not reflected in the next GET would otherwise run the
    /// same request twice.
    private var lastExecutedCommandID: String?

    /// Conversations change on the order of minutes, and the scan stats every
    /// transcript. Re-reading the whole history every ten seconds is work
    /// nobody asked for.
    private var cachedConversations: (at: Date, value: [ClaudeConversation])?

    /// The status line last sent. Comparing the rendered text is the whole
    /// rate limit: the strip only moves when something a human would notice
    /// moves, so a percentage ticking down does not send a push per percent.
    private var lastStatusLine: String?

    /// `EX_USAGE`, which is what the script exits with when it does not
    /// recognise its arguments.
    private static let usageError: Int32 = 64

    /// What the phone sees of a past conversation. The title is already on the
    /// user's phone in the Claude app, and the project name is already
    /// published for live sessions — the directory is not, and never is.
    private struct PublishedConversation: Equatable, Encodable {
        let id: String
        let title: String
        let project: String
        let lastActive: String

        enum CodingKeys: String, CodingKey {
            case id, title, project
            case lastActive = "last_active"
        }
    }

    /// What leaves the machine. Deliberately narrow: no prompt, no tool line,
    /// no path — those are the sensitive part of what the notch shows, and the
    /// phone only needs to answer "which one needs me?".
    private struct PublishedSession: Equatable, Encodable {
        let id: String
        let project: String
        let agent: String
        let status: String
        let startedAt: String
        let subagents: Int

        enum CodingKeys: String, CodingKey {
            case id, project, agent, status, subagents
            case startedAt = "started_at"
        }

        static func opaqueID(_ sessionID: String, key: SymmetricKey) -> String {
            HMAC<SHA256>.authenticationCode(for: Data(sessionID.utf8), using: key)
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
        }

        init(_ session: Session, formatter: ISO8601DateFormatter, key: SymmetricKey) {
            // The phone only needs something stable to key a row on, and the
            // real value is the Claude session UUID — an identifier that can
            // be correlated elsewhere. A truncated digest gives the phone
            // exactly the uniqueness it needs and nothing it can trace back,
            // and the Mac can still match a row by recomputing it.
            id = Self.opaqueID(session.id, key: key)
            project = session.project
            agent = session.agent
            status = switch session.displayStatus {
            case .working: "working"
            case .needsMe: "needs_me"
            case .done: "done"
            case .idle: "idle"
            }
            startedAt = formatter.string(from: session.startedAt ?? session.updatedAt)
            subagents = session.subagents
        }
    }

    /// One provider's slice of the wire contract. Rendered by hand rather
    /// than through `JSONEncoder`: on Darwin, `JSONEncoder`'s keyed
    /// containers go through an unordered dictionary before serializing, so
    /// the same value can come out with its keys in a different order on
    /// every encode — exactly the "dictionary reorders itself" case that
    /// would make `publishUsageIfChanged()`'s change-detection fire on an
    /// unchanged snapshot.
    fileprivate struct PublishedUsageProvider: Equatable {
        let plan: String?
        let account: String?
        let windows: [PublishedUsageWindow]
    }

    /// One quota window. Field order here IS the wire order.
    fileprivate struct PublishedUsageWindow: Equatable {
        let kind: String
        let percentUsed: Double
        let resetsAt: String?
        let scope: String?
        let severity: String
        let expectedPercent: Double?
        let deltaPercent: Double?
        let runsOutAt: String?
    }

    /// One provider's slice of the token-history wire contract. Rendered by
    /// hand for the same reason `PublishedUsageProvider` is: a stable key
    /// order across encodes of an identical value.
    fileprivate struct PublishedUsageHistoryProvider: Equatable {
        let days: [PublishedUsageHistoryDay]
        let topModel: String?
    }

    /// One calendar day's total. Field order here IS the wire order.
    fileprivate struct PublishedUsageHistoryDay: Equatable {
        let day: String
        let tokens: Int
    }

    // nil until the first successful reconcile; then the on/off value both
    // sides last agreed on, so a local toggle can be told apart from a stale
    // remote flag.
    private var lastSyncedActive: Bool?

    private var isConfigured: Bool {
        FileManager.default.fileExists(atPath: pairingURL.path)
    }

    private func observeChanges() {
        withObservationTracking {
            _ = engine.mode
            _ = engine.lastOffReason
            _ = engine.isOnACPower
            _ = sessionStore.sessions
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isStarted else { return }
                self.observeChanges()
                await self.checkNow()
            }
        }
    }

    private func evaluateBattery() async {
        let snapshot = powerSourceProvider.snapshot()
        guard !snapshot.isOnACPower else {
            previousBatteryPercent = nil
            sentBatteryThresholds.removeAll()
            return
        }
        guard let percent = snapshot.percent else { return }

        if percent > 55 {
            sentBatteryThresholds.removeAll()
        }

        if let previousBatteryPercent {
            for threshold in Self.batteryThresholds
                where previousBatteryPercent > threshold
                    && percent <= threshold
                    && !sentBatteryThresholds.contains(threshold) {
                sentBatteryThresholds.insert(threshold)
                await push(
                    title: "Vibenotch",
                    body: t("Battery at %d%% — Gotta go! is on", threshold),
                    tag: "battery-\(threshold)"
                )
            }
        }
        previousBatteryPercent = percent
    }

    private func evaluateNeedsMeSessions() async {
        var current: [String: String] = [:]
        for session in sessionStore.sessions where session.displayStatus == .needsMe {
            current[session.id] = session.project
        }
        needsMeSessionIDs.formIntersection(current.keys)

        let key = sessionIDKey
        for sessionID in current.keys.sorted()
            where !needsMeSessionIDs.contains(sessionID) {
            guard let project = current[sessionID] else { continue }
            needsMeSessionIDs.insert(sessionID)
            await push(
                title: "Vibenotch",
                body: t("Needs you: %@", project),
                // The opaque id, not the session's own: the tag is stored in
                // the notification history, and publishing the real id there
                // would undo the whole point of hashing it in the first place.
                tag: "needs-me-\(PublishedSession.opaqueID(sessionID, key: key))"
            )
        }
    }

    /// The remote flag is the DESIRED state, reconciled in both directions:
    /// the phone can start a session as well as kill one, and a local toggle
    /// is pushed up so the phone never shows a stale answer. (It used to be
    /// kill-only, with an ack that reset the flag to true — which is exactly
    /// why turning Gotta go! *on* from the phone did nothing.)
    /// /api/state answers with the on/off flag AND the settings blob, so one
    /// GET per tick feeds both reconcilers.
    private func reconcileRemote() async {
        resetSettingsRevIfPairingChanged()
        let result = await run(["--state"])
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let remote = try? JSONDecoder().decode(RemoteStateWithSettings.self, from: data)
        else { return }

        if let desired = remote.keepAwakeEnabled {
            await reconcileDesiredState(desired)
        }
        await reconcileSettings(remote)
        await publishMachineStateIfChanged()
        await publishSessionsIfChanged(remoteCount: remote.sessions?.count ?? 0)
        await publishResumableIfChanged(remoteCount: remote.resumable?.count ?? 0)
        // Ask before publishing, on a five-minute cadence rather than the
        // bridge's ten-second one. Opening the quota tab was the only thing
        // that ever fetched these, so the phone would have shown whatever was
        // last looked at on the Mac — or nothing at all.
        usageStore.refreshIfStale(maxAge: UsageStore.backgroundMaxAge, now: Date())
        // Same reasoning for the local token-history scan: it used to run
        // only when the quota tab opened. `scanLocalIfNeeded()` is a no-op
        // once a scan has run or is running, so asking every tick costs
        // nothing after the first.
        usageStore.scanLocalIfNeeded()
        await publishUsageIfChanged()
        await publishUsageHistoryIfChanged()
        await publishRemoteControlIfChanged(remoteValue: remote.remoteControl)
        await updateStatusStrip(enabled: remote.statusNotification == true)
        await runPendingCommand(remote.command)
    }

    private func reconcileDesiredState(_ desired: Bool) async {
        let isActive = engine.isActive
        if desired == isActive {
            lastSyncedActive = isActive
            return
        }

        // Toggled on the Mac since the last agreement: the local truth wins and
        // is published, so the phone shows "On" when you flip the bolt here.
        // (On the very first reconcile there is nothing to compare against, so
        // the remote value is treated as the desired state.)
        if let lastSyncedActive, lastSyncedActive != isActive {
            await pushDesiredState(isActive)
            return
        }

        if desired {
            let startMode = engine.config.defaultMode == .off
                ? KeepAwakeMode.whileAgentsWork
                : engine.config.defaultMode
            engine.setMode(startMode, now: Date())
            lastSyncedActive = engine.isActive

            // The engine can REFUSE: it will not start while the Mac is
            // already critically hot. Reporting success anyway told the phone
            // a lie and left the remote flag on, so the next poll tried again,
            // was refused again, and sent the same cheerful confirmation —
            // forever, once a minute, for something that never happened.
            guard engine.isActive else {
                await pushDesiredState(false)
                await push(
                    title: "Vibenotch",
                    body: t("Gotta go! could not start — the Mac is too hot"),
                    tag: "remote-toggle"
                )
                return
            }

            await push(
                title: "Vibenotch",
                body: t("Gotta go! turned on remotely ✓"),
                // One tag for both directions: they are the same fact, and
                // separate tags meant an on and an off sat side by side in the
                // shade saying opposite things.
                tag: "remote-toggle"
            )
        } else {
            engine.setMode(.off, now: Date())
            lastSyncedActive = false
            await push(
                title: "Vibenotch",
                body: t("Gotta go! turned off remotely ✓"),
                tag: "remote-toggle"
            )
        }
    }

    private func pushDesiredState(_ enabled: Bool) async {
        let body = #"{"keep_awake_enabled":\#(enabled)}"#
        let result = await run(["--state-put"], stdin: body)
        if result.exitCode == 0 {
            lastSyncedActive = enabled
        }
    }

    /// The phone warns about the battery but could never show it. Published on
    /// change only — the state endpoint is a write, and an unchanged percentage
    /// is not news.
    ///
    /// Heat rides along in the same write: it moves on the same timescale, and
    /// it matters most in the situation the phone exists for — the Mac working
    /// with the lid shut, where you cannot feel how hot it has become.
    private func publishMachineStateIfChanged() async {
        // Serialised like the session publisher, and for the same reason:
        // @MainActor does not prevent reentrancy across an `await`, so two
        // ticks could both pass the guard, and the older curl finishing last
        // would leave the phone — and the cache — holding the stale reading.
        guard !isPublishingMachineState else {
            machineStateChangedWhilePublishing = true
            return
        }
        isPublishingMachineState = true
        defer { isPublishingMachineState = false }

        await publishMachineStateNow()

        // `while`, not `if`: a change arriving DURING the follow-up publish
        // sets the flag again, and a single retry would return holding it —
        // leaving the phone on a stale battery or thermal reading until some
        // later reconcile happened to notice. `publishSessionsIfChanged` has
        // drained in a loop all along; this one only retried once.
        while machineStateChangedWhilePublishing {
            machineStateChangedWhilePublishing = false
            await publishMachineStateNow()
        }
    }

    private func publishMachineStateNow() async {
        let snapshot = powerSourceProvider.snapshot()
        let thermal = engine.thermalState.wireName
        let battery = snapshot.percent.map {
            PublishedBattery(percent: $0, isOnACPower: snapshot.isOnACPower)
        }

        // Two caches, not one, because the wire has no way to say "the battery
        // reading is gone": /api/state is a partial update, so omitting the
        // field preserves whatever was there. A combined cache would record the
        // absence as published and then suppress the correction forever.
        var fields: [String] = []
        if let battery, battery != lastPublishedBattery {
            fields.append(#""battery":{"percent":\#(battery.percent),"on_ac":\#(battery.isOnACPower)}"#)
        }
        if thermal != lastPublishedThermal {
            fields.append(#""thermal_state":"\#(thermal)""#)
        }
        guard !fields.isEmpty else { return }

        // Battery and heat ONLY. Sending the on/off flag alongside would write
        // back a value read before the poll, so a toggle made on the phone in
        // that window would be silently overwritten instead of obeyed.
        let body = "{" + fields.joined(separator: ",") + "}"
        guard await run(["--state-put"], stdin: body).exitCode == 0 else { return }
        if let battery { lastPublishedBattery = battery }
        lastPublishedThermal = thermal
    }

    /// Publishes the session list so the phone can show which agent needs you,
    /// not merely that one does. On change only — the list is stable for
    /// minutes at a time and /api/state is a write.
    /// Serialises publishes. `observeChanges()` re-arms before an in-flight
    /// POST returns, so two curls could otherwise carry an older and a newer
    /// snapshot at once — and whichever the server wrote last would win,
    /// which is not necessarily the newer one.
    private var isPublishingSessions = false
    private var sessionsChangedWhilePublishing = false

    private func publishSessionsIfChanged(remoteCount: Int?) async {
        guard !isPublishingSessions else {
            sessionsChangedWhilePublishing = true
            return
        }
        isPublishingSessions = true
        defer { isPublishingSessions = false }

        await publishSessionsNow(remoteCount: remoteCount)

        // Anything that arrived while the write was in flight is published
        // after it, in order, rather than racing it.
        while sessionsChangedWhilePublishing {
            sessionsChangedWhilePublishing = false
            await publishSessionsNow(remoteCount: remoteCount)
        }
    }

    private func publishSessionsNow(remoteCount: Int?) async {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Capped to match the server's own limit, so the two agree on what a
        // full snapshot is rather than the server silently truncating.
        let key = sessionIDKey
        let snapshot = sessionStore.sessions.prefix(20).map {
            PublishedSession($0, formatter: formatter, key: key)
        }
        guard Array(snapshot) != lastPublishedSessions else { return }

        // Nothing to say when both sides are already empty — but an empty list
        // over a non-empty remote IS worth a write, or a phone keeps showing
        // sessions that ended before the Mac last restarted. Only relevant
        // before the first publish; after that the comparison above decides.
        if snapshot.isEmpty, lastPublishedSessions == nil, remoteCount == 0 {
            lastPublishedSessions = []
            return
        }

        // Nothing published yet and no reading of the remote to compare
        // against: leave it to the next poll rather than guess.
        if lastPublishedSessions == nil, remoteCount == nil { return }

        guard let payload = try? JSONEncoder().encode(["sessions": Array(snapshot)]),
              let body = String(data: payload, encoding: .utf8)
        else { return }

        if await run(["--state-put"], stdin: body).exitCode == 0 {
            lastPublishedSessions = Array(snapshot)
        }
    }

    /// Past conversations the phone can ask the Mac to reopen. Published on
    /// change only, like everything else on this channel.
    private func publishResumableIfChanged(remoteCount: Int) async {
        let key = sessionIDKey
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let snapshot = await conversations().map {
            PublishedConversation(
                id: PublishedSession.opaqueID($0.id, key: key),
                title: $0.title,
                project: $0.project,
                lastActive: formatter.string(from: $0.lastActive)
            )
        }
        guard snapshot != lastPublishedResumable else { return }

        // Same rule as the session list: nothing to say when both sides are
        // already empty, but an empty list over a non-empty remote is worth a
        // write.
        if snapshot.isEmpty, remoteCount == 0 {
            lastPublishedResumable = []
            return
        }

        guard let payload = try? JSONEncoder().encode(["resumable": snapshot]),
              let body = String(data: payload, encoding: .utf8)
        else { return }

        if await run(["--state-put"], stdin: body).exitCode == 0 {
            lastPublishedResumable = snapshot
        }
    }

    /// Publishes the Claude/Codex quota gauges so the phone can draw the same
    /// bars the notch does. On change only, compared on the rendered JSON —
    /// same rule as the status strip. Never triggers a refresh itself: this
    /// publishes whatever `UsageStore` already holds, and a provider with
    /// nothing loaded is left out of the object entirely rather than sent as
    /// null.
    /// Serialised, for the same reason `publishSessionsIfChanged` is.
    ///
    /// The check against the last published body and the write that follows it
    /// are separated by an await, and the actor is free to run another tick in
    /// that gap — the ten-second timer and an observation-driven `checkNow()`
    /// overlap routinely. Two passes could then post the same body twice, and
    /// if two different bodies finished out of order the older one would win
    /// both the remote row and the cache, freezing the phone on stale numbers
    /// until something else changed.
    private var isPublishingUsage = false

    private func publishUsageIfChanged() async {
        guard !isPublishingUsage else { return }
        guard let body = renderedUsagePayload() else { return }
        let digest = Self.payloadDigest(body)
        guard digest != lastPublishedUsageDigest else { return }

        isPublishingUsage = true
        defer { isPublishingUsage = false }

        if await run(["--state-put"], stdin: body).exitCode == 0 {
            lastPublishedUsageDigest = digest
            userDefaults.set(digest, forKey: Self.lastPublishedUsageDigestKey)
        }
    }

    private func renderedUsagePayload() -> String? {
        // ITERATES the enum rather than naming providers by hand — including
        // in the emptiness check below, which is where the hand-written
        // version survived its own fix. Asking `claude == nil, codex == nil`
        // meant a Grok-only account never got past the first-publish gate: the
        // notch drew its card and the phone stayed blank, which is precisely
        // the bug the loop was written to end. Grok also lost any tick where
        // it had finished while the other two were still loading, because that
        // gate never ran when Claude happened to be present.
        let providers = UsageProviderKind.allCases.compactMap { kind -> String? in
            guard let provider = publishedUsageProvider(for: kind) else { return nil }
            return "\"\(kind.rawValue)\":\(renderedUsageProvider(provider))"
        }

        if providers.isEmpty {
            // Loading is ignorance, not an empty result. Once every attempted
            // fetch has settled, however, a prior successful publish must be
            // cleared or the phone keeps quotas that no provider can supply.
            let entries = usageStore.entries.values
            let hasFinishedFetch = !entries.isEmpty && !entries.contains { entry in
                if case .loading = entry { return true }
                return false
            }
            guard hasFinishedFetch, lastPublishedUsageDigest != nil else { return nil }
        }

        return "{\"usage\":{\(providers.joined(separator: ","))}}"
    }

    private func renderedUsageProvider(_ provider: PublishedUsageProvider) -> String {
        let windows = provider.windows.map(renderedUsageWindow).joined(separator: ",")
        return "{\"plan\":\(jsonStringOrNull(provider.plan))"
            + ",\"account\":\(jsonStringOrNull(provider.account))"
            + ",\"windows\":[\(windows)]}"
    }

    private func renderedUsageWindow(_ window: PublishedUsageWindow) -> String {
        "{\"kind\":\(jsonString(window.kind))"
            + ",\"percent_used\":\(jsonNumber(window.percentUsed))"
            + ",\"resets_at\":\(jsonStringOrNull(window.resetsAt))"
            + ",\"scope\":\(jsonStringOrNull(window.scope))"
            + ",\"severity\":\(jsonString(window.severity))"
            + ",\"expected_percent\":\(jsonNumberOrNull(window.expectedPercent))"
            + ",\"delta_percent\":\(jsonNumberOrNull(window.deltaPercent))"
            + ",\"runs_out_at\":\(jsonStringOrNull(window.runsOutAt))}"
    }

    private func publishedUsageProvider(for kind: UsageProviderKind) -> PublishedUsageProvider? {
        guard case .loaded(let snapshot) = usageStore.entries[kind] else { return nil }

        // Pace as of when the SNAPSHOT was captured, not as of now.
        //
        // `expectedPercent` moves with the clock, so computing it from `Date()`
        // made the rendered body differ on every single tick — and the whole
        // publisher is built on "publish only when the body changes". Measured
        // against production: `usage_updated_at` advanced every ten seconds,
        // roughly 8,600 writes a day for a number that genuinely changes about
        // three hundred times. The phone re-derives nothing from this; it draws
        // what arrives, and a five-minute-old expected percentage is well
        // inside the honesty of a bar you glance at.
        let pace = usageStore.pace(for: snapshot, now: snapshot.capturedAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let windows = snapshot.windows.map { window -> PublishedUsageWindow in
            let windowPace = pace[window.id]
            return PublishedUsageWindow(
                kind: window.kind == .session ? "session" : "weekly",
                percentUsed: window.percentUsed,
                resetsAt: window.resetsAt.map { formatter.string(from: $0) },
                scope: window.scopeLabel,
                severity: window.severity.rawValue,
                expectedPercent: windowPace?.expectedPercent,
                deltaPercent: windowPace?.deltaPercent,
                runsOutAt: windowPace?.runsOutAt.map { formatter.string(from: $0) }
            )
        }
        return PublishedUsageProvider(plan: snapshot.plan, account: snapshot.account, windows: windows)
    }

    /// Publishes the per-day token history the local scan builds, so the
    /// phone can draw the same bar chart the notch does instead of saying
    /// history is unavailable. On change only, compared on the rendered
    /// JSON — same rule as `publishUsageIfChanged()`. Never triggers the scan
    /// itself: `reconcileRemote()` asks for that separately, and this
    /// publishes whatever `UsageStore` already holds.
    /// Same reentrancy rule as the quota publisher above.
    private var isPublishingUsageHistory = false

    private func publishUsageHistoryIfChanged() async {
        guard !isPublishingUsageHistory else { return }
        guard let body = renderedUsageHistoryPayload() else { return }
        let digest = Self.payloadDigest(body)
        guard digest != lastPublishedUsageHistoryDigest else { return }

        isPublishingUsageHistory = true
        defer { isPublishingUsageHistory = false }

        if await run(["--state-put"], stdin: body).exitCode == 0 {
            lastPublishedUsageHistoryDigest = digest
            userDefaults.set(digest, forKey: Self.lastPublishedUsageHistoryDigestKey)
        }
    }

    private func renderedUsageHistoryPayload() -> String? {
        let claude = publishedUsageHistoryProvider(for: .claude)
        let codex = publishedUsageHistoryProvider(for: .codex)

        // A nil series means the restart scan has not answered yet. Clearing
        // during that gap would make valid history flicker away on every app
        // launch and would turn each launch into two unnecessary writes.
        guard usageStore.localSeries != nil else { return nil }

        // Nothing at all to report, and nothing was ever reported: stay quiet.
        // But once something HAS been published, silence stops being neutral —
        // the payload replaces only the keys it carries, so an omitted
        // provider keeps whatever the remote last saw. A provider whose last
        // day ages out of the window would leave the phone drawing a chart
        // that no longer exists anywhere else. So after the first publish we
        // always say something, even if what we have to say is "nothing".
        let rendered = UsageProviderKind.allCases.compactMap { kind -> String? in
            guard let provider = publishedUsageHistoryProvider(for: kind) else { return nil }
            return "\"\(kind.rawValue)\":\(renderedUsageHistoryProvider(provider))"
        }
        guard !rendered.isEmpty || lastPublishedUsageHistoryDigest != nil else { return nil }
        return "{\"usage_history\":{\(rendered.joined(separator: ","))}}"
    }

    private func renderedUsageHistoryProvider(_ provider: PublishedUsageHistoryProvider) -> String {
        let days = provider.days.map(renderedUsageHistoryDay).joined(separator: ",")
        return "{\"days\":[\(days)],\"top_model\":\(jsonStringOrNull(provider.topModel))}"
    }

    private func renderedUsageHistoryDay(_ day: PublishedUsageHistoryDay) -> String {
        "{\"day\":\(jsonString(day.day)),\"tokens\":\(day.tokens)}"
    }

    /// One provider's trailing-window slice of the local scan, or nil when it
    /// has no days in that window — a provider that is a scan away from
    /// having anything is omitted entirely rather than sent with an empty
    /// `days` array, matching `publishedUsageProvider(for:)`'s rule for the
    /// network-fetched quotas.
    private func publishedUsageHistoryProvider(for kind: UsageProviderKind) -> PublishedUsageHistoryProvider? {
        guard let series = usageStore.localSeries else { return nil }

        let calendar = Calendar.current
        let cutoff = calendar.date(
            byAdding: .day, value: -(UsageStore.trailingDays - 1),
            to: calendar.startOfDay(for: Date())
        )
        // Zero-token days are dropped, not just days absent from the scan:
        // the wire contract says a gap is drawn rather than a flat zero, and
        // `totalTokens` could in principle be zero without the point being
        // absent.
        let days = series.points
            .filter { $0.provider == kind && $0.totalTokens > 0 }
            .filter { point in
                guard let cutoff else { return true }
                return point.day >= cutoff
            }
            .sorted { $0.day < $1.day }
        guard !days.isEmpty else { return nil }

        // Same rule the notch's own chart uses (`UsageHistoryChart`): the top
        // model is the top model of the single biggest day in the window,
        // not a sum across days — the scanner only ever hands back one
        // model per day, never a per-model breakdown across the whole
        // series.
        let topModel = days.max(by: { $0.totalTokens < $1.totalTokens })?.topModel
        let renderedDays = days.map {
            PublishedUsageHistoryDay(day: Self.wireDayString($0.day), tokens: $0.totalTokens)
        }
        return PublishedUsageHistoryProvider(days: renderedDays, topModel: topModel)
    }

    /// `YYYY-MM-DD` in the Mac's local time zone. The scanner already buckets
    /// `point.day` to local midnight (`Calendar.current.startOfDay`), so this
    /// only has to read the components back out — never re-interpreting the
    /// instant in another zone, which is exactly what the phone must not do
    /// either.
    private static func wireDayString(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// The phone can ask for exactly one thing, and it cannot say how.
    ///
    /// The request carries an opaque id and nothing else: no path, no command,
    /// no arguments. The Mac resolves that id against conversations IT indexed
    /// and IT published, and builds the command itself. A request naming
    /// anything the Mac did not publish is dropped — so the worst a stolen
    /// pairing secret buys is reopening a conversation that is already on that
    /// machine, never running something of the attacker's choosing.
    private func runPendingCommand(_ command: RemoteCommand?) async {
        // An empty slot means the request that was here has been retired, so
        // the dedupe has done its job. Forgetting it now is what lets the same
        // conversation be reopened again later — closing the terminal and
        // asking a second time is a normal thing to do, and remembering
        // forever would refuse it until the app restarted.
        guard let command else {
            lastExecutedCommandID = nil
            return
        }
        if command.action == "remote_control" || command.action == "remote_control_stop" {
            await changeRemoteControl(
                starting: command.action == "remote_control",
                requestID: command.id ?? command.action ?? "remote-control"
            )
            return
        }

        guard command.action == "resume", let requestedID = command.id else { return }

        // Already done — but the slot still has to be freed, or a repeat jams
        // it shut and every later request is refused with a conflict.
        if requestedID == lastExecutedCommandID {
            _ = await run(["--state-put"], stdin: #"{"clear_command_id":"\#(requestedID)"}"#)
            return
        }

        let key = sessionIDKey
        let match = await conversations().first {
            PublishedSession.opaqueID($0.id, key: key) == requestedID
        }

        // Clear FIRST, and only act if the clear stuck. Acting on a request
        // still sitting in the remote means the next poll sees it again — and
        // this action opens a Terminal window and starts a Claude process, so
        // "retry until it works" would be a new window every ten seconds.
        // Names the id being acknowledged so the server can make the clear
        // conditional: an unconditional one would discard a request the phone
        // wrote after this poll read.
        let acknowledgement = #"{"clear_command_id":"\#(requestedID)"}"#
        guard await run(["--state-put"], stdin: acknowledgement).exitCode == 0 else {
            NSLog("Vibenotch left a resume request in place: could not clear it")
            return
        }
        lastExecutedCommandID = requestedID

        guard let match else {
            NSLog("Vibenotch ignored a resume request for an unknown conversation")
            return
        }

        if resumer.resume(match) {
            await push(
                title: "Vibenotch",
                body: t("Reopening %@ on the Mac — connect from the Claude app", match.title),
                tag: "resume-\(requestedID)"
            )
        }
    }

    /// Off the main actor: the scan stats every transcript in every project,
    /// and this class is @MainActor, so doing it inline stalls the notch and
    /// the settings window on a machine with a long history.
    private func conversations() async -> [ClaudeConversation] {
        if let cachedConversations, Date().timeIntervalSince(cachedConversations.at) < 60 {
            return cachedConversations.value
        }
        let index = conversationIndex
        let value = await Task.detached(priority: .utility) {
            index.recentConversations()
        }.value
        cachedConversations = (Date(), value)
        return value
    }

    /// Whether a remote-control server is up, so the phone's button can show
    /// the state rather than always offering to start one.
    private func publishRemoteControlIfChanged(remoteValue: Bool?) async {
        let server = remoteControlServer
        // pgrep is a process spawn; off the main actor like the transcript
        // scan, for the same reason.
        let running = await Task.detached(priority: .utility) { server.isRunning() }.value

        // Compared against what the remote already holds rather than a local
        // copy: a local cache would publish once on every launch just to say
        // what the server already knew.
        guard running != (remoteValue ?? false) else { return }
        _ = await run(["--state-put"], stdin: #"{"remote_control":\#(running)}"#)
    }

    /// Starts the server in the most recently active project. Server mode
    /// serves sessions from its own directory, and the last place the user was
    /// working is the best guess available without asking them to pick one.
    private func changeRemoteControl(starting: Bool, requestID: String) async {
        // NOT taken from the resumable list: that one hides untitled
        // conversations, so a fresh install or anyone who never renames one
        // would have had the button silently do nothing.
        let index = conversationIndex
        let directory = starting
            ? await Task.detached(priority: .utility) { index.mostRecentDirectory() }.value
            : nil
        guard await run(["--state-put"], stdin: #"{"clear_command_id":"\#(requestID)"}"#).exitCode == 0
        else {
            NSLog("Vibenotch left a remote-control request in place: could not clear it")
            return
        }

        guard starting else {
            let server = remoteControlServer
            await Task.detached(priority: .utility) { server.stop() }.value
            // Published straight away rather than left to the next tick: the
            // phone asked for this and should not watch a stale "on" for ten
            // seconds while wondering whether the tap registered.
            _ = await run(["--state-put"], stdin: #"{"remote_control":false}"#)
            return
        }

        guard let directory else {
            // Say so rather than fail silently: the tap has to produce
            // something, and "there is no project to start in" is the answer.
            await push(
                title: "Vibenotch",
                body: t("No project to start remote control in — open one on the Mac first"),
                tag: "remote-control-empty"
            )
            return
        }
        if resumer.startRemoteControl(in: directory) {
            await push(
                title: "Vibenotch",
                body: t("Remote control starting on the Mac — pick it in the Claude app"),
                tag: "remote-control"
            )
        }
    }

    /// A silent, always-replaced notification carrying the state at a glance.
    ///
    /// Opt-in, and sent only when the line itself changes — a strip that
    /// re-sent on every tick would cost battery and train the user to turn the
    /// app's notifications off, which would take the real alerts with them.
    private func updateStatusStrip(enabled: Bool) async {
        guard enabled else {
            lastStatusLine = nil
            return
        }

        let sessions = sessionStore.sessions
        let working = sessions.filter { $0.displayStatus == .working }.count
        let needsMe = sessions.filter { $0.displayStatus == .needsMe }.count

        // The headline is whatever would make you pick the phone up: someone
        // waiting on you beats work in progress, which beats nothing running.
        let title: String
        if needsMe > 0 {
            title = t("%d need you", needsMe)
        } else if working > 0 {
            title = t("%d working", working)
        } else {
            title = t("No agents running")
        }

        // One line per session, like the notch itself, then the Mac's own
        // state last — it is the least surprising thing on the list.
        var lines = sessions.prefix(Self.statusStripSessionLines).map {
            "\($0.project) · \(Self.statusWord($0.displayStatus))"
        }
        if sessions.count > Self.statusStripSessionLines {
            lines.append(t("+%d more", sessions.count - Self.statusStripSessionLines))
        }

        var macState = [engine.isActive ? t("Gotta go! on") : t("Gotta go! off")]
        let power = powerSourceProvider.snapshot()
        if let percent = power.percent {
            macState.append(power.isOnACPower ? t("%d%% charging", percent) : t("%d%%", percent))
        }
        // Only when it is bad news. The strip is glanced at, not read.
        switch engine.thermalState {
        case .serious: macState.append(t("hot"))
        case .critical: macState.append(t("overheating"))
        default: break
        }
        lines.append(macState.joined(separator: " · "))

        let body = lines.joined(separator: "\n")
        // Compared as one value: the strip should move when anything shown on
        // it moves, and not otherwise.
        let rendered = title + "\n" + body
        guard rendered != lastStatusLine else { return }

        // A tag of its own: replacing itself is the point, and it must never
        // replace a real "needs you" alert.
        //
        // Cached only on success. Recording it before knowing the push landed
        // means one transient failure suppresses every retry — and on a Mac at
        // 100% on AC with nothing running, the line may not change again for
        // hours, so the strip would simply never appear.
        if await run([title, body, "status", "--silent"]).exitCode == 0 {
            lastStatusLine = rendered
        }
    }

    /// Enough lines to be useful, few enough that the shade stays readable.
    private static let statusStripSessionLines = 3

    private static func statusWord(_ status: DisplayStatus) -> String {
        switch status {
        case .working: t("working")
        case .needsMe: t("needs you")
        // Not t("done"): that key is the plural count in the notch header, so
        // a single session read "alpha · concluídos".
        case .done: t("finished")
        case .idle: t("idle")
        }
    }

    private func push(title: String, body: String, tag: String? = nil) async {
        var arguments = [title, body]
        if let tag {
            arguments.append(tag)
        }
        _ = await run(arguments)
    }

    // Remote rev wins on conflict: a newer remote rev always overwrites the
    // local config and re-baselines the sync snapshot, so the same tick
    // never also pushes local values back up for that rev. Only once the
    // rev is caught up do local edits get a chance to push.
    /// A different remote instance starts its own revision counter, and a
    /// remote rev is only applied when it is strictly greater than the last one
    /// seen — so re-pairing to a fresh instance would silently ignore its
    /// settings until it caught up with the old one's counter. Moving the URL
    /// drops the baseline.
    private func resetSettingsRevIfPairingChanged() {
        guard let data = try? Data(contentsOf: pairingURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = object["url"] as? String,
              userDefaults.string(forKey: Self.pairedRemoteURLKey) != url
        else { return }

        userDefaults.set(url, forKey: Self.pairedRemoteURLKey)
        lastAppliedSettingsRev = 0
        // Everything cached about the old remote is now wrong. Without this a
        // newly paired phone shows no charge until the percentage happens to
        // move — and at 100% on AC that can be hours.
        lastPublishedBattery = nil
        lastPublishedThermal = nil
        lastPublishedSessions = nil
        lastPublishedResumable = nil
        lastPublishedUsageDigest = nil
        lastPublishedUsageHistoryDigest = nil
        userDefaults.removeObject(forKey: Self.lastPublishedUsageDigestKey)
        userDefaults.removeObject(forKey: Self.lastPublishedUsageHistoryDigestKey)
        lastStatusLine = nil
        lastSyncedActive = nil
    }

    private static func payloadDigest(_ body: String) -> String {
        // 128 bits is ample for change detection while keeping preferences to
        // a short, non-reversible marker rather than the user-facing payload.
        SHA256.hash(data: Data(body.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func reconcileSettings(_ remote: RemoteStateWithSettings) async {
        let remoteRev = remote.settingsRev ?? 0
        if remoteRev > lastAppliedSettingsRev {
            if let settings = remote.settings {
                applyRemoteSettings(settings)
            }
            lastAppliedSettingsRev = remoteRev
            lastSyncedSettingsSnapshot = RemoteSettingsSnapshot(engine.config)
            return
        }

        let currentSnapshot = RemoteSettingsSnapshot(engine.config)
        guard currentSnapshot != lastSyncedSettingsSnapshot else { return }

        let payload: [String: Any] = [
            "settings": currentSnapshot.remoteJSONObject,
            "base_rev": lastAppliedSettingsRev,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let stdin = String(data: body, encoding: .utf8)
        else { return }

        // A 409 (the phone wrote first) exits non-zero, so the snapshot stays
        // dirty and the next tick retries on top of the newer rev.
        let pushResult = await run(["--settings-put"], stdin: stdin)
        if pushResult.exitCode == 0 {
            // Next poll's --state will see the bumped rev and re-apply
            // these same values as if they were a remote change — harmless,
            // since applying them is a no-op once the snapshot already
            // matches. That one-cycle-lag keeps this side simple.
            lastSyncedSettingsSnapshot = currentSnapshot
        }
    }

    private func applyRemoteSettings(_ settings: RemoteSettingsPayload) {
        var config = engine.config
        if let modeString = settings.defaultMode,
           let mode = KeepAwakeSettingsLogic.defaultMode(fromRemote: modeString) {
            config.defaultMode = mode
        }
        if let value = settings.allowDisplaySleep { config.allowDisplaySleep = value }
        if let value = settings.closedLidMode { config.closedLidMode = value }
        if let value = settings.autoOffOnUnlock { config.autoOffOnUnlock = value }
        if let value = settings.batteryFloorPercent {
            config.batteryFloorPercent = KeepAwakeSettingsLogic.clampedBatteryFloor(value)
        }
        if let value = settings.graceMinutes {
            config.graceSeconds = KeepAwakeSettingsLogic.graceSeconds(from: value)
        }
        if let value = settings.reminderHours {
            config.reminderAfterIdleSeconds = KeepAwakeSettingsLogic.reminderSeconds(from: value)
        }
        engine.config = config
    }

    @discardableResult
    private func run(_ arguments: [String], stdin: String? = nil) async -> CommandRunResult {
        let result = await commandRunner.run(arguments: arguments, stdin: stdin)
        // 64 is the script's usage error: it did not understand what it was
        // asked for. That means the installed scripts are older than this app
        // — the app keeps calling, the script keeps refusing, and nothing
        // says so. It cost an afternoon once; it should be visible.
        if result.exitCode == Self.usageError {
            NSLog(
                "Vibenotch: installed scripts are out of date (rejected %@). Run ./scripts/install.sh",
                arguments.first ?? ""
            )
            userDefaults.set(true, forKey: Self.scriptMismatchKey)
        } else if result.exitCode == 0 {
            userDefaults.set(false, forKey: Self.scriptMismatchKey)
        } else {
            NSLog(
                "Vibenotch vibenotch-remote-push %@ exited with status %d",
                arguments.first ?? "",
                result.exitCode
            )
        }
        return result
    }
}

/// Minimal hand-rolled JSON scalar rendering for the usage payload — see
/// `RemoteBridge.PublishedUsageProvider` for why `JSONEncoder` is not used
/// for this one value on this platform.
private func jsonString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    result += "\""
    return result
}

private func jsonStringOrNull(_ value: String?) -> String {
    value.map(jsonString) ?? "null"
}

private func jsonNumber(_ value: Double) -> String {
    String(value)
}

private func jsonNumberOrNull(_ value: Double?) -> String {
    value.map(jsonNumber) ?? "null"
}

/// The seven remote-managed fields of `KeepAwakeConfig`, mapped to the wire
/// format used by /api/state and /api/settings. Equatable so RemoteBridge
/// can detect local drift with a plain `!=` against the last-synced value.
private struct RemoteSettingsSnapshot: Equatable {
    var defaultMode: String
    var allowDisplaySleep: Bool
    var closedLidMode: Bool
    var autoOffOnUnlock: Bool
    var batteryFloorPercent: Int
    var graceMinutes: Int
    var reminderHours: Double

    init(_ config: KeepAwakeConfig) {
        defaultMode = KeepAwakeSettingsLogic.remoteDefaultModeString(config.defaultMode)
        allowDisplaySleep = config.allowDisplaySleep
        closedLidMode = config.closedLidMode
        autoOffOnUnlock = config.autoOffOnUnlock
        batteryFloorPercent = config.batteryFloorPercent
        graceMinutes = KeepAwakeSettingsLogic.graceMinutes(from: config.graceSeconds)
        reminderHours = KeepAwakeSettingsLogic.reminderHours(from: config.reminderAfterIdleSeconds)
    }

    var remoteJSONObject: [String: Any] {
        [
            "defaultMode": defaultMode,
            "allowDisplaySleep": allowDisplaySleep,
            "closedLidMode": closedLidMode,
            "autoOffOnUnlock": autoOffOnUnlock,
            "batteryFloorPercent": batteryFloorPercent,
            "graceMinutes": graceMinutes,
            "reminderHours": reminderHours,
        ]
    }
}

private struct RemoteSettingsPayload: Decodable {
    var defaultMode: String?
    var allowDisplaySleep: Bool?
    var closedLidMode: Bool?
    var autoOffOnUnlock: Bool?
    var batteryFloorPercent: Int?
    var graceMinutes: Int?
    var reminderHours: Double?
}

/// Field-less on purpose: only the count is needed, to tell "the remote still
/// lists sessions that have ended" from "both sides are already empty".
private struct RemoteSessionCount: Decodable {}

struct RemoteCommand: Decodable {
    let action: String?
    let id: String?
}

private struct RemoteStateWithSettings: Decodable {
    let keepAwakeEnabled: Bool?
    let command: RemoteCommand?
    let settings: RemoteSettingsPayload?
    let sessions: [RemoteSessionCount]?
    let resumable: [RemoteSessionCount]?
    let remoteControl: Bool?
    let statusNotification: Bool?
    let settingsRev: Int?

    enum CodingKeys: String, CodingKey {
        case keepAwakeEnabled = "keep_awake_enabled"
        case settings
        case sessions
        case resumable
        case remoteControl = "remote_control"
        case statusNotification = "status_notification"
        // The column is `pending_command`, and GET returns it under that name.
        // Decoding "command" silently found nothing, so the Mac never saw a
        // request — and the unit test missed it because its fixture used the
        // key this decoder wanted rather than the one the API returns.
        case command = "pending_command"
        case settingsRev = "settings_rev"
    }
}
