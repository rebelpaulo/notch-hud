import CryptoKit
import Foundation
import Testing
@testable import Vibenotch

@MainActor
@Test func remoteBridgeTracksBatteryThresholdsAndResetsTheDischargeCycle() async throws {
    let fixture = try RemoteBridgeFixture(percent: 60, onAC: false)
    defer { fixture.remove() }

    await fixture.bridge.checkNow()
    fixture.power.percent = 49
    await fixture.bridge.checkNow()
    await fixture.bridge.checkNow()
    fixture.power.percent = 19
    await fixture.bridge.checkNow()

    var calls = await fixture.runner.recordedCalls()
    #expect(calls.map(\.dropTag) == [
        ["Vibenotch", "Battery at 50% — Gotta go! is on"],
        ["Vibenotch", "Battery at 30% — Gotta go! is on"],
        ["Vibenotch", "Battery at 20% — Gotta go! is on"]
    ])

    fixture.power.isOnACPower = true
    await fixture.bridge.checkNow()
    fixture.power.isOnACPower = false
    fixture.power.percent = 60
    await fixture.bridge.checkNow()
    fixture.power.percent = 50
    await fixture.bridge.checkNow()

    calls = await fixture.runner.recordedCalls()
    #expect(calls.last?.dropTag == ["Vibenotch", "Battery at 50% — Gotta go! is on"])
}

@MainActor
@Test func remoteBridgeDeduplicatesNeedsMeUntilTheSessionLeaves() async throws {
    let fixture = try RemoteBridgeFixture()
    defer { fixture.remove() }

    fixture.store.sessions = [remoteSession(id: "s1", project: "Álbum", status: .needs_me)]
    await fixture.bridge.checkNow()
    await fixture.bridge.checkNow()
    fixture.store.sessions = [remoteSession(id: "s1", project: "Álbum", status: .working)]
    await fixture.bridge.checkNow()
    fixture.store.sessions = [remoteSession(id: "s1", project: "Álbum", status: .needs_me)]
    await fixture.bridge.checkNow()

    let calls = await fixture.runner.recordedCalls()
    #expect(calls.map(\.dropTag) == [
        ["Vibenotch", "Needs you: Álbum"],
        ["Vibenotch", "Needs you: Álbum"]
    ])
}

@MainActor
@Test func remoteBridgeReportsOnlyTheAgentsWorkGraceOffTransition() async throws {
    let fixture = try RemoteBridgeFixture(mode: .whileAgentsWork)
    defer { fixture.remove() }
    await fixture.bridge.checkNow()

    fixture.engine.mode = .off
    fixture.engine.lastOffReason = .whileAgentsWorkGrace
    await fixture.bridge.checkNow()
    await fixture.bridge.checkNow()

    let calls = await fixture.runner.recordedCalls()
    #expect(calls.map(\.dropTag) == [[
        "Vibenotch", "All agents finished — Gotta go! turned itself off"
    ]])
}

@MainActor
@Test func remoteBridgeObeysRemoteOffAndConfirms() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0}"#)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == .off)
    #expect(await fixture.runner.recordedCalls() == [
        ["--state"],
        ["Vibenotch", "Gotta go! turned off remotely ✓", "remote-toggle"],
        // Heat publishes on every first poll, with or without a battery reading.
        ["--state-put"]
    ])
}

@MainActor
@Test func remoteBridgeTurnsAllNighterOnFromThePhone() async throws {
    // The whole point of the bidirectional contract: engine off + remote true
    // must START a session using the configured default mode.
    let fixture = try RemoteBridgeFixture(
        mode: .off,
        stateOutput: #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.mode == fixture.engine.config.defaultMode)
    #expect(await fixture.runner.recordedCalls().contains(
        ["Vibenotch", "Gotta go! turned on remotely ✓", "remote-toggle"]
    ))
}

@MainActor
@Test func remoteBridgePublishesLocalToggleSoThePhoneShowsTheTruth() async throws {
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        stateOutput: #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#
    )
    defer { fixture.remove() }

    // First reconcile agrees: both sides on.
    await fixture.bridge.checkNow(pollRemoteState: true)

    // Toggled off ON THE MAC: local truth wins and is pushed up, and the
    // stale remote "true" must NOT switch it back on.
    fixture.engine.mode = .off
    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.lastStatePutBody())
    #expect(body.contains("\"keep_awake_enabled\":false"))
    #expect(fixture.engine.mode == .off)
}

@MainActor
@Test func remoteBridgeReconcilesOnALocalToggleWithoutWaitingForTheNextPoll() async throws {
    // observeChanges() calls checkNow() with pollRemoteState: false. The phone
    // would still be showing "On" a poll cycle later if that path skipped the
    // reconcile, which is what the user saw as lag.
    let fixture = try RemoteBridgeFixture(mode: .manual)
    defer { fixture.remove() }
    await fixture.bridge.checkNow(pollRemoteState: true)

    fixture.engine.mode = .off
    await fixture.bridge.checkNow()

    let body = try #require(await fixture.runner.lastStatePutBody())
    #expect(body.contains("\"keep_awake_enabled\":false"))
    #expect(fixture.engine.mode == .off)
}

@MainActor
@Test func remoteBridgeSyncsStateAndSettingsWhileInactiveWithoutPushing() async throws {
    let fixture = try RemoteBridgeFixture(
        mode: .off,
        percent: 10,
        onAC: false,
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0}"#
    )
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "Quiet", status: .needs_me)]

    await fixture.bridge.checkNow(pollRemoteState: true)

    // No battery/needs-me *notifications* while off, but state and settings
    // reconcile so the phone can both configure and start the next session —
    // and the charge is published so the phone can show it.
    // Two writes, each saying one thing: the charge, and the session list.
    let calls = await fixture.runner.recordedCalls()
    #expect(calls == [["--state"], ["--state-put"], ["--state-put"]])
    let bodies = await fixture.runner.statePutBodies()
    let battery = try #require(bodies.first { $0.contains("battery") })
    #expect(battery.contains("\"percent\":10"))
    #expect(battery.contains("\"on_ac\":false"))
}

@MainActor
@Test func remoteBridgePublishesOnlyTheNarrowSessionFields() async throws {
    // The privacy contract, pinned: the phone gets enough to answer "which one
    // needs me?" and nothing that reveals what is being written or where. A
    // future field added to Session must not silently ride along.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    fixture.store.sessions = [
        remoteSession(id: "s1", project: "vibenotch", status: .working)
    ]

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.statePutBodies().first { $0.contains("sessions") })
    let sessions = try #require(
        JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: [[String: Any]]]
    )["sessions"]
    let entry = try #require(sessions?.first)
    #expect(Set(entry.keys) == ["id", "project", "agent", "status", "started_at", "subagents"])
    // The id must not be the session's own identifier: that is the Claude
    // session UUID, which is correlatable elsewhere. Stable and opaque.
    let published = try #require(entry["id"] as? String)
    #expect(published != "s1")
    #expect(published.count == 16)
    #expect(published.allSatisfy { $0.isHexDigit })

    // An unkeyed digest of a low-entropy id (Codex terminal sessions are
    // "codex-<PID>") is recoverable by anyone who can enumerate the space, so
    // the plain SHA-256 of the id must NOT be what we published.
    let unkeyed = SHA256.hash(data: Data("s1".utf8))
        .prefix(8)
        .map { String(format: "%02x", $0) }
        .joined()
    #expect(published != unkeyed)
}

@MainActor
@Test func remoteBridgeKeepsTheSessionDigestStableAcrossTicks() async throws {
    // Stable or the phone re-keys every row on every poll; per-installation or
    // two Macs publish the same digest for the same session id.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .working)]

    await fixture.bridge.checkNow(pollRemoteState: true)
    let first = try #require(await fixture.runner.statePutBodies().first { $0.contains("sessions") })

    fixture.store.sessions = [
        remoteSession(id: "s1", project: "vibenotch", status: .needs_me)
    ]
    await fixture.bridge.checkNow(pollRemoteState: true)
    let second = try #require(await fixture.runner.statePutBodies().last { $0.contains("sessions") })

    func digest(_ body: String) throws -> String {
        let json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: [[String: Any]]]
        return try #require(json?["sessions"]?.first?["id"] as? String)
    }
    #expect(try digest(first) == digest(second))
}

@MainActor
@Test func remoteBridgePublishesASessionChangeWithoutWaitingForTheNextPoll() async throws {
    // The Mac knows the instant a session changes. Waiting for the ten-second
    // tick to say so left the phone up to fifteen seconds behind, which reads
    // as "it did not update" and gets answered with a manual refresh.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .working)]
    await fixture.bridge.checkNow(pollRemoteState: true)
    let afterPoll = await fixture.runner.statePutBodies().filter { $0.contains("sessions") }.count

    // An observation tick: no poll, just the store changing.
    fixture.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .needs_me)]
    await fixture.bridge.checkNow()

    let bodies = await fixture.runner.statePutBodies().filter { $0.contains("sessions") }
    #expect(bodies.count == afterPoll + 1)
    #expect(try #require(bodies.last).contains("needs_me"))
}

@MainActor
@Test func statusStripIsOptInAndOnlySentWhenTheLineChanges() async throws {
    // A strip that re-sent on every tick would cost battery and train the user
    // to turn the app's notifications off, taking the real alerts with them.
    let off = try RemoteBridgeFixture(mode: .manual, percent: 80, onAC: false)
    defer { off.remove() }
    off.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .working)]
    await off.bridge.checkNow(pollRemoteState: true)
    #expect(await off.runner.recordedCalls().contains { $0.contains("status") } == false)

    let on = try RemoteBridgeFixture(
        mode: .manual,
        percent: 80,
        onAC: false,
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"status_notification":true}"#
    )
    defer { on.remove() }
    on.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .working)]

    await on.bridge.checkNow(pollRemoteState: true)
    let first = await on.runner.recordedCalls().filter { $0.contains("status") }
    #expect(first.count == 1)
    let call = try #require(first.first)
    // Title carries the headline, body the detail — like the notification it
    // is trying to look like.
    #expect(call[0] == "1 working")
    #expect(call[1].contains("vibenotch · working"))
    #expect(call[1].contains("80%"))
    #expect(call.contains("--silent"))

    // Nothing changed: no second push.
    await on.bridge.checkNow(pollRemoteState: true)
    #expect(await on.runner.recordedCalls().filter { $0.contains("status") }.count == 1)

    // Something a human would notice did change.
    on.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .needs_me)]
    await on.bridge.checkNow(pollRemoteState: true)
    #expect(await on.runner.recordedCalls().filter { $0.contains("status") }.count == 2)
}

@MainActor
@Test func statusStripListsSessionsAndCapsTheList() async throws {
    // The point of going multi-line is naming the projects. Capped so the
    // shade stays readable rather than becoming a scrolling list.
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        percent: 55,
        onAC: true,
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"status_notification":true}"#
    )
    defer { fixture.remove() }
    fixture.store.sessions = [
        remoteSession(id: "s1", project: "alpha", status: .needs_me),
        remoteSession(id: "s2", project: "beta", status: .working),
        remoteSession(id: "s3", project: "gamma", status: .working),
        remoteSession(id: "s4", project: "delta", status: .working),
        remoteSession(id: "s5", project: "epsilon", status: .working),
    ]

    await fixture.bridge.checkNow(pollRemoteState: true)

    let call = try #require(await fixture.runner.recordedCalls().first { $0.contains("status") })
    // Someone waiting on you outranks work in progress in the headline.
    #expect(call[0] == "1 need you")
    let lines = call[1].split(separator: "\n").map(String.init)
    #expect(lines.count == 5) // 3 sessions + "+2 more" + the Mac's own state
    #expect(lines[0] == "alpha · needs you")
    #expect(lines[3] == "+2 more")
    #expect(lines[4].contains("55% charging"))
}

@MainActor
@Test func aScriptThatRejectsItsArgumentsIsRecordedAsOutOfDate() async throws {
    // The real failure: the app is newer than the installed scripts, so it
    // keeps asking for something they do not understand and they keep
    // refusing. Nothing in the interface said so, and it cost an afternoon.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: 80, onAC: false)
    defer { fixture.remove() }
    await fixture.runner.setExitCode(64)

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.defaults.bool(forKey: RemoteBridge.scriptMismatchKey))

    // And it clears itself once the scripts are updated, rather than warning
    // forever about a problem that is gone.
    await fixture.runner.setExitCode(0)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(!fixture.defaults.bool(forKey: RemoteBridge.scriptMismatchKey))
}

@MainActor
@Test func statusStripRetriesAfterAFailedPush() async throws {
    // Caching the line before knowing the push landed means one transient
    // failure suppresses every retry — and on a Mac at 100% on AC with
    // nothing running, the line may not change again for hours.
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        percent: 80,
        onAC: false,
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"status_notification":true}"#
    )
    defer { fixture.remove() }
    await fixture.runner.failPushes(true)

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.recordedCalls().filter { $0.contains("status") }.count == 1)

    await fixture.runner.failPushes(false)
    await fixture.bridge.checkNow(pollRemoteState: true)

    // Nothing about the Mac changed; the retry happened because the first
    // attempt never landed.
    #expect(await fixture.runner.recordedCalls().filter { $0.contains("status") }.count == 2)
}

@MainActor
@Test func remoteBridgePublishesSessionsBeforeAwaitingANotification() async throws {
    // The needs-me push allows ten seconds for its transfer. Awaiting it
    // before publishing would put the delay right back where this removed it.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    await fixture.bridge.checkNow(pollRemoteState: true)
    fixture.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .needs_me)]

    await fixture.bridge.checkNow()

    let calls = await fixture.runner.recordedCalls()
    let publish = try #require(calls.lastIndex(of: ["--state-put"]))
    let notify = try #require(calls.lastIndex { $0.count == 3 && $0[2].hasPrefix("needs-me-") })
    #expect(publish < notify)
}

@MainActor
@Test func remoteBridgeDoesNotPublishSessionsBeforeItHasSeenTheRemote() async throws {
    // Without a reading of the remote there is nothing to compare an empty
    // list against, so the first word should come from a poll, not a guess.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }

    await fixture.bridge.checkNow()

    #expect(await fixture.runner.recordedCalls().isEmpty)
}

@MainActor
@Test func remoteBridgeDoesNotRepublishAnUnchangedSessionList() async throws {
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    fixture.store.sessions = [
        remoteSession(id: "s1", project: "vibenotch", status: .working)
    ]

    await fixture.bridge.checkNow(pollRemoteState: true)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.statePutBodies().filter { $0.contains("sessions") }.count == 1)
}

@MainActor
@Test func remoteBridgePublishesTheBatteryOnceUntilItChanges() async throws {
    // /api/state is a write. Ten identical readings a minute is not news, and
    // the phone already has the number.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: 80, onAC: false)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)
    await fixture.bridge.checkNow(pollRemoteState: true)
    let afterUnchanged = await fixture.runner.recordedCalls()
        .filter { $0 == ["--state-put"] }
        .count
    #expect(afterUnchanged == 1)

    fixture.power.percent = 79
    await fixture.bridge.checkNow(pollRemoteState: true)

    let afterChange = await fixture.runner.recordedCalls()
        .filter { $0 == ["--state-put"] }
        .count
    #expect(afterChange == 2)
    #expect(try #require(await fixture.runner.lastStatePutBody()).contains("\"percent\":79"))
}

@MainActor
@Test func remoteBridgeNeverWritesTheToggleWhenPublishingTheBattery() async throws {
    // The Mac reads the flag, then reports its charge. If that report carried
    // the flag, a toggle made on the phone inside that window would be
    // overwritten with the value read before it — the phone's request lost
    // rather than obeyed.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: 55, onAC: false)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.lastStatePutBody())
    #expect(body.contains("\"percent\":55"))
    #expect(!body.contains("keep_awake_enabled"))
}

@MainActor
@Test func remoteBridgeRepublishesTheBatteryAfterRepairing() async throws {
    // Re-pairing points at a phone that has never seen a reading. At 100% on
    // AC the value can sit unchanged for hours, so without clearing the cache
    // the new phone shows no battery at all.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: 100, onAC: true)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.recordedCalls().filter { $0 == ["--state-put"] }.count == 1)

    try fixture.repair(url: "https://other.example")
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.runner.recordedCalls().filter { $0 == ["--state-put"] }.count == 2)
}

@MainActor
@Test func needsMeNotificationTagCarriesTheOpaqueIDNotTheRealOne() async throws {
    // The tag is stored in the notification history the phone reads back, so a
    // raw session id there would undo the hashing done everywhere else.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    fixture.store.sessions = [remoteSession(id: "s1", project: "vibenotch", status: .needs_me)]

    await fixture.bridge.checkNow()

    let tags = await fixture.runner.recordedCalls()
        .filter { $0.count == 3 }
        .map { $0[2] }
    let needsMe = try #require(tags.first { $0.hasPrefix("needs-me-") })
    #expect(needsMe != "needs-me-s1")
    #expect(needsMe.dropFirst("needs-me-".count).count == 16)
}

@MainActor
@Test func remoteBridgeResumesTheConversationBehindAPublishedID() async throws {
    // The full round trip: the Mac indexes a conversation, publishes an opaque
    // id for it, and resumes the right one when that id comes back. The id is
    // read from what was actually published rather than recomputed here, so
    // the test cannot pass by agreeing with a wrong implementation.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    try fixture.writeConversation(
        sessionID: "aaaaaaaa-1111-2222-3333-444444444444",
        title: "Revenge ads meta",
        directory: "/Users/mac/Claude code"
    )

    await fixture.bridge.checkNow(pollRemoteState: true)
    let published = try #require(
        await fixture.runner.statePutBodies().first { $0.contains("resumable") }
    )
    let resumable = try #require(
        JSONSerialization.jsonObject(with: Data(published.utf8)) as? [String: [[String: Any]]]
    )["resumable"]
    let entry = try #require(resumable?.first)
    #expect(entry["title"] as? String == "Revenge ads meta")
    #expect(entry["project"] as? String == "Claude code")
    // The directory never leaves the Mac; the phone gets the project name only.
    #expect(entry["directory"] == nil)
    let publishedID = try #require(entry["id"] as? String)

    await fixture.runner.setStateOutput(
        #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"pending_command":{"action":"resume","id":"\#(publishedID)"}}"#
    )
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.resumer.resumed.map(\.id) == ["aaaaaaaa-1111-2222-3333-444444444444"])
}

@MainActor
@Test func remoteBridgeStopsTheRemoteControlServerOnRequest() async throws {
    // Symmetry matters here: with only a start, the button is dead exactly
    // when you want it — when the server is running and you want it stopped.
    let stopped = Stopped()
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        percent: nil,
        onAC: true,
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"remote_control":true,"pending_command":{"action":"remote_control_stop","id":"remote_control_stop"}}"#,
        remoteControlServer: RemoteControlServer(runProcess: { path, _ in
            if path.hasSuffix("pkill") { stopped.value = true }
            return path.hasSuffix("pgrep") ? 0 : 0
        })
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(stopped.value)
    let bodies = await fixture.runner.statePutBodies()
    #expect(bodies.contains { $0.contains(#""remote_control":false"#) })
}

final class Stopped: @unchecked Sendable {
    var value = false
}

@MainActor
@Test func remoteBridgeReopensTheSameConversationASecondTime() async throws {
    // Closing the terminal and asking again is a normal thing to do. The
    // dedupe existed for a stale read of one request, not to refuse that
    // conversation for the rest of the session.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    try fixture.writeConversation(
        sessionID: "aaaaaaaa-1111-2222-3333-444444444444",
        title: "Revenge ads meta",
        directory: "/Users/mac/Claude code"
    )
    await fixture.bridge.checkNow(pollRemoteState: true)
    let published = try #require(
        await fixture.runner.statePutBodies().first { $0.contains("resumable") }
    )
    let entry = try #require(
        (JSONSerialization.jsonObject(with: Data(published.utf8)) as? [String: [[String: Any]]])?["resumable"]?.first
    )
    let publishedID = try #require(entry["id"] as? String)
    let request = #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"pending_command":{"action":"resume","id":"\#(publishedID)"}}"#

    await fixture.runner.setStateOutput(request)
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.resumer.resumed.count == 1)

    // The Mac sees the slot empty (it cleared it), then the user asks again.
    await fixture.runner.setStateOutput(#"{"keep_awake_enabled":false,"settings":{},"settings_rev":0}"#)
    await fixture.bridge.checkNow(pollRemoteState: true)
    await fixture.runner.setStateOutput(request)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.resumer.resumed.count == 2)
}

@MainActor
@Test func remoteBridgeDoesNotActOnACommandItCouldNotClear() async throws {
    // This action opens a Terminal window and starts a Claude process. Acting
    // while the request is still sitting in the remote means the next poll
    // sees it again — a new window every ten seconds until a clear succeeds.
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }
    try fixture.writeConversation(
        sessionID: "aaaaaaaa-1111-2222-3333-444444444444",
        title: "Revenge ads meta",
        directory: "/Users/mac/Claude code"
    )
    await fixture.bridge.checkNow(pollRemoteState: true)
    let published = try #require(
        await fixture.runner.statePutBodies().first { $0.contains("resumable") }
    )
    let entry = try #require(
        (JSONSerialization.jsonObject(with: Data(published.utf8)) as? [String: [[String: Any]]])?["resumable"]?.first
    )
    let publishedID = try #require(entry["id"] as? String)

    await fixture.runner.setStateOutput(
        #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"pending_command":{"action":"resume","id":"\#(publishedID)"}}"#
    )
    await fixture.runner.failStatePut(true)
    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.resumer.resumed.isEmpty)
}

@MainActor
@Test func remoteBridgeResumesOnlyAConversationItPublishedItself() async throws {
    // The security boundary, pinned. The phone sends an opaque id and nothing
    // else — no path, no command — and the Mac resolves it against its own
    // index. An id it never published must be dropped, or a stolen pairing
    // secret becomes a way to run something of the attacker's choosing.
    let fixture = try RemoteBridgeFixture(
        mode: .manual,
        percent: nil,
        onAC: true,
        stateOutput: #"{"keep_awake_enabled":false,"settings":{},"settings_rev":0,"pending_command":{"action":"resume","id":"deadbeefdeadbeef"}}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(await fixture.resumer.resumed.isEmpty)
    // Cleared regardless, or an unmatched request retries every ten seconds
    // for the rest of the session.
    let bodies = await fixture.runner.statePutBodies()
    #expect(bodies.contains { $0.contains("\"clear_command_id\":\"deadbeefdeadbeef\"") })
}

@MainActor
@Test func remoteBridgeKeepsPublishingTheBatteryAfterAReadingGoesMissing() async throws {
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: 80, onAC: false)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    // /api/state is a partial update, so there is no way to say "the battery
    // reading is gone" — omitting the field preserves the last one. Recording
    // the absence as published is what would suppress the correction forever.
    fixture.power.percent = nil
    await fixture.bridge.checkNow(pollRemoteState: true)
    fixture.power.percent = 79
    await fixture.bridge.checkNow(pollRemoteState: true)

    let bodies = await fixture.runner.statePutBodies()
    #expect(bodies.filter { $0.contains("\"battery\"") } == [
        #"{"battery":{"percent":80,"on_ac":false},"thermal_state":"nominal"}"#,
        #"{"battery":{"percent":79,"on_ac":false}}"#
    ])
}

@MainActor
@Test func remoteBridgeSkipsTheBatteryWhenThereIsNoReadingButStillPublishesHeat() async throws {
    let fixture = try RemoteBridgeFixture(mode: .manual, percent: nil, onAC: true)
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    // A Mac with no battery reading still has a temperature, and heat is the
    // half of this write that matters with the lid shut.
    let bodies = await fixture.runner.statePutBodies()
    #expect(bodies == [#"{"thermal_state":"nominal"}"#])
}

@MainActor
@Test func remoteBridgeAppliesConfigWhenRemoteRevIsHigher() async throws {
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"defaultMode":"whileAppsRunning","allowDisplaySleep":false,"batteryFloorPercent":30},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.defaultMode == .whileAppsRunning)
    #expect(!fixture.engine.config.allowDisplaySleep)
    #expect(fixture.engine.config.batteryFloorPercent == 30)
    #expect(await fixture.runner.recordedCalls() == [["--state"], ["--state-put"]])
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)
}

@MainActor
@Test func remoteBridgeSameRevIsANoOp() async throws {
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":30},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(fixture.engine.config.batteryFloorPercent == 30)

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.batteryFloorPercent == 30)
    #expect(await fixture.runner.recordedCalls().filter { $0 == ["--settings-put"] }.isEmpty)
}

@MainActor
@Test func remoteBridgePushesLocalConfigChangeUp() async throws {
    let fixture = try RemoteBridgeFixture()
    defer { fixture.remove() }

    // Baseline poll: remote rev (0) matches lastAppliedSettingsRev (0),
    // local config hasn't moved from the fixture's initial snapshot yet.
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)

    fixture.engine.config.allowDisplaySleep = false
    fixture.engine.config.batteryFloorPercent = 35

    await fixture.bridge.checkNow(pollRemoteState: true)

    let body = try #require(await fixture.runner.lastSettingsPutBody())
    let pushed = try #require(
        JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    )
    let settings = try #require(pushed["settings"] as? [String: Any])
    #expect(settings["allowDisplaySleep"] as? Bool == false)
    #expect(settings["batteryFloorPercent"] as? Int == 35)
    // Without base_rev the write is unconditional and silently overwrites a
    // phone edit made between this tick's GET and PUT.
    #expect(pushed["base_rev"] as? Int == 0)
}

@MainActor
@Test func remoteBridgeDropsTheSettingsRevBaselineWhenThePairingMovesToAnotherRemote() async throws {
    // A fresh remote restarts its counter at 0, and revs only apply when
    // strictly greater — so without this the new remote's settings would be
    // ignored until it caught up with the old one's numbering.
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":45},"settings_rev":9}"#
    )
    defer { fixture.remove() }
    await fixture.bridge.checkNow(pollRemoteState: true)
    #expect(fixture.engine.config.batteryFloorPercent == 45)

    try fixture.repair(url: "https://other.example")
    let moved = try RemoteBridgeFixture(
        reusing: fixture,
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"batteryFloorPercent":15},"settings_rev":1}"#
    )

    await moved.bridge.checkNow(pollRemoteState: true)

    #expect(moved.engine.config.batteryFloorPercent == 15)
}

@MainActor
@Test func remoteBridgeIgnoresMalformedRemoteSettingsWithoutCrashing() async throws {
    let fixture = try RemoteBridgeFixture(stateOutput: "not json")
    defer { fixture.remove() }
    let before = fixture.engine.config

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config == before)
    #expect(await fixture.runner.recordedCalls().contains(["--settings-put"]) == false)
}

@MainActor
@Test func remoteBridgeIgnoresUnknownDefaultModeStringWithoutCrashing() async throws {
    let fixture = try RemoteBridgeFixture(
        stateOutput: #"{"keep_awake_enabled":true,"settings":{"defaultMode":"bogus","allowDisplaySleep":false},"settings_rev":1}"#
    )
    defer { fixture.remove() }

    await fixture.bridge.checkNow(pollRemoteState: true)

    #expect(fixture.engine.config.defaultMode == .whileAgentsWork)
    #expect(!fixture.engine.config.allowDisplaySleep)
}

@MainActor
final class FakeConversationResumer: ConversationResuming {
    private(set) var resumed: [ClaudeConversation] = []
    private(set) var remoteControlDirectories: [String] = []
    var succeeds = true

    func resume(_ conversation: ClaudeConversation) -> Bool {
        resumed.append(conversation)
        return succeeds
    }

    func startRemoteControl(in directory: String) -> Bool {
        remoteControlDirectories.append(directory)
        return succeeds
    }
}

@MainActor
private final class RemoteBridgeFixture {
    let scratch: URL
    let engine: FakeRemoteEngine
    let store = FakeRemoteStore()

    let runner: FakeRemoteCommandRunner
    let power: FakeRemotePowerSource
    let resumer = FakeConversationResumer()
    let bridge: RemoteBridge

    private let suiteName: String
    let defaults: UserDefaults

    init(
        mode: KeepAwakeMode = .manual,
        percent: Int? = nil,
        onAC: Bool = true,
        stateOutput: String = #"{"keep_awake_enabled":true,"settings":{},"settings_rev":0}"#,
        config: KeepAwakeConfig = KeepAwakeConfig(),
        remoteControlServer: RemoteControlServer = RemoteControlServer(runProcess: { _, _ in 1 })
    ) throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = scratch.appendingPathComponent(".vibenotch", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try #"{"url":"https://remote.example","secret":"test-secret"}"#.write(
            to: configDirectory.appendingPathComponent("remote.json"),
            atomically: true,
            encoding: .utf8
        )

        engine = FakeRemoteEngine(mode: mode, isOnACPower: onAC, config: config)
        runner = FakeRemoteCommandRunner(stateOutput: stateOutput)
        power = FakeRemotePowerSource(percent: percent, isOnACPower: onAC)
        suiteName = "RemoteBridgeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: store,
            commandRunner: runner,
            powerSourceProvider: power,
            homeURL: scratch,
            userDefaults: defaults,
            resumer: resumer,
            // Never spawn a real pgrep from a test: the answer would depend on
            // what happens to be running on the machine.
            remoteControlServer: remoteControlServer
        )
    }

    /// Builds a second bridge over the same scratch home and UserDefaults, the
    /// way a relaunch after re-pairing would see them.
    init(reusing other: RemoteBridgeFixture, stateOutput: String) throws {
        scratch = other.scratch
        engine = other.engine
        runner = FakeRemoteCommandRunner(stateOutput: stateOutput)
        power = other.power
        suiteName = other.suiteName
        defaults = other.defaults
        bridge = RemoteBridge(
            engine: engine,
            sessionStore: other.store,
            commandRunner: runner,
            powerSourceProvider: power,
            homeURL: scratch,
            userDefaults: defaults,
            resumer: resumer,
            remoteControlServer: RemoteControlServer(runProcess: { _, _ in 1 })
        )
    }

    func repair(url: String) throws {
        try #"{"url":"\#(url)","secret":"test-secret"}"#.write(
            to: scratch.appendingPathComponent(".vibenotch/remote.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeConversation(sessionID: String, title: String, directory: String) throws {
        let projects = scratch
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent("encoded-path", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(sessionID)"}"#,
            #"{"type":"user","cwd":"\#(directory)"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: projects.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: scratch)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
private final class FakeRemoteEngine: RemoteKeepAwakeEngine {
    var mode: KeepAwakeMode
    var isOnACPower: Bool
    var thermalState: ProcessInfo.ThermalState = .nominal
    var lastOffReason: KeepAwakeOffReason?
    var config: KeepAwakeConfig
    var isActive: Bool { mode != .off }

    init(mode: KeepAwakeMode, isOnACPower: Bool, config: KeepAwakeConfig = KeepAwakeConfig()) {
        self.mode = mode
        self.isOnACPower = isOnACPower
        self.config = config
    }

    func setMode(_ newMode: KeepAwakeMode, now: Date) {
        mode = newMode
        lastOffReason = nil
    }
}

@MainActor
private final class FakeRemoteStore: RemoteSessionStoring {
    var sessions: [Session] = []
}

private final class FakeRemotePowerSource: PowerSourceProviding, @unchecked Sendable {
    var percent: Int?
    var isOnACPower: Bool

    init(percent: Int?, isOnACPower: Bool) {
        self.percent = percent
        self.isOnACPower = isOnACPower
    }
}

private actor FakeRemoteCommandRunner: CommandRunning {
    private var calls: [[String]] = []
    private var stdins: [String?] = []
    private var stateOutput: String

    func setStateOutput(_ value: String) {
        stateOutput = value
    }
    private var settingsPutExitCode: Int32 = 0
    private var statePutFails = false
    private var pushesFail = false
    private var forcedExitCode: Int32?

    func setExitCode(_ code: Int32?) {
        forcedExitCode = code
    }

    func failStatePut(_ value: Bool) {
        statePutFails = value
    }

    func failPushes(_ value: Bool) {
        pushesFail = value
    }

    init(stateOutput: String) {
        self.stateOutput = stateOutput
    }

    func setSettingsPutExitCode(_ code: Int32) {
        settingsPutExitCode = code
    }

    func run(arguments: [String], stdin: String?) async -> CommandRunResult {
        calls.append(arguments)
        stdins.append(stdin)
        if let forcedExitCode {
            return CommandRunResult(
                stdout: arguments == ["--state"] ? stateOutput : "{}",
                exitCode: forcedExitCode
            )
        }
        if arguments == ["--settings-put"] {
            return CommandRunResult(stdout: "", exitCode: settingsPutExitCode)
        }
        if arguments == ["--state-put"], statePutFails {
            return CommandRunResult(stdout: "", exitCode: 1)
        }
        // Identified by shape, not by title: the status strip's title is now
        // computed, so matching on a literal silently stopped matching.
        if pushesFail, arguments.count >= 3 {
            return CommandRunResult(stdout: "", exitCode: 1)
        }
        return CommandRunResult(
            stdout: arguments == ["--state"] ? stateOutput : "{}",
            exitCode: 0
        )
    }

    func recordedCalls() -> [[String]] {
        calls
    }

    func lastSettingsPutBody() -> String? {
        guard let index = calls.lastIndex(of: ["--settings-put"]) else { return nil }
        return stdins[index]
    }

    func lastStatePutBody() -> String? {
        guard let index = calls.lastIndex(of: ["--state-put"]) else { return nil }
        return stdins[index]
    }

    /// Every `--state-put` body, so a test can name the write it means rather
    /// than assume which one happened to be last.
    func statePutBodies() -> [String] {
        zip(calls, stdins)
            .filter { $0.0 == ["--state-put"] }
            .compactMap { $0.1 }
    }
}

private extension Array where Element == String {
    var dropTag: [String] {
        Array(prefix(2))
    }
}

private func remoteSession(id: String, project: String, status: SessionStatus) -> Session {
    Session(
        envelope: SessionEnvelope(
            schema: 1,
            id: id,
            agent: "codex",
            project: project,
            status: status,
            updated: "2026-08-06T12:00:00Z",
            seq: 1
        ),
        updatedAt: Date(timeIntervalSince1970: 1_000_000)
    )
}
