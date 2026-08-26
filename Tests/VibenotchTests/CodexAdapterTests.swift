import Foundation
import Testing

@Test func codexNotifyEmitsDoneWithExplicitSessionIdentity() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // notify is update-only: seed the session the way the shim would.
    _ = try runCodexScript(
        "vibenotch-emit",
        arguments: ["codex-explicit", "codex", "working", "--source", "codex"],
        home: scratch
    )

    let payload = #"{"type":"agent-turn-complete","thread-id":"thread-ignored"}"#
    let result = try runCodexScript(
        "vibenotch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: ["NOTCH_CODEX_SESSION_ID": "codex-explicit"]
    )

    #expect(result.status == 0)
    let envelope = try codexPayload(id: "codex-explicit", home: scratch)
    #expect(envelope["status"] as? String == "done")
    #expect(envelope["source"] as? String == "codex")
    #expect(envelope["id"] as? String == "codex-explicit")
}

@Test func codexNotifyEmitsNeedsMeForApprovalPayload() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    _ = try runCodexScript(
        "vibenotch-emit",
        arguments: ["codex-approval-thread", "codex", "working", "--source", "codex"],
        home: scratch
    )

    let payload = #"{"type":"exec-approval-request","conversation_id":"approval-thread"}"#
    let result = try runCodexScript("vibenotch-codex-notify", arguments: [payload], home: scratch)

    #expect(result.status == 0)
    let envelope = try codexPayload(id: "codex-approval-thread", home: scratch)
    #expect(envelope["status"] as? String == "needs_me")
    #expect(envelope["source"] as? String == "codex")
}

@Test func codexNotifyIgnoresUnknownPayload() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let result = try runCodexScript(
        "vibenotch-codex-notify",
        arguments: [#"{"type":"unrelated-event"}"#],
        home: scratch,
        extraEnvironment: ["NOTCH_CODEX_SESSION_ID": "codex-unknown"]
    )

    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("sessions/codex-unknown.json").path))
}

@Test func codexNotifyNeverCreatesSessions() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // A late turn-complete after the shim already removed the session (codex
    // fires notify asynchronously) must not resurrect it as a ghost.
    let payload = #"{"type":"agent-turn-complete"}"#
    let result = try runCodexScript(
        "vibenotch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: ["NOTCH_CODEX_SESSION_ID": "codex-ghost"]
    )

    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("sessions/codex-ghost.json").path))
}

@Test func codexNotifyCreatesDesktopSessionsFromAppTurnEnd() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    // Codex Desktop client → creation allowed, keyed like the rollout poller
    let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"019fca6a-be3f-7ee1-a864-fbf884a1692f","cwd":"/tmp/projects/aquarium"}"#
    let result = try runCodexScript("vibenotch-codex-notify", arguments: [payload], home: scratch)

    #expect(result.status == 0)
    let envelope = try codexPayload(id: "codex-app-019fca6a", home: scratch)
    #expect(envelope["status"] as? String == "done")
    #expect(envelope["source"] as? String == "codex-desktop")
    #expect(envelope["project"] as? String == "aquarium")
    #expect(envelope["cwd"] as? String == "/tmp/projects/aquarium")

    // desktop approval requests surface as needs_me on the same entry
    let approval = #"{"type":"exec-approval-request","client":"Codex Desktop","thread-id":"019fca6a-be3f-7ee1-a864-fbf884a1692f","cwd":"/tmp/projects/aquarium"}"#
    _ = try runCodexScript("vibenotch-codex-notify", arguments: [approval], home: scratch)
    let updated = try codexPayload(id: "codex-app-019fca6a", home: scratch)
    #expect(updated["status"] as? String == "needs_me")

    // exec client without an existing session still refuses creation
    let execPayload = #"{"type":"agent-turn-complete","client":"codex_exec","thread-id":"deadbeef-0000-0000-0000-000000000000"}"#
    _ = try runCodexScript("vibenotch-codex-notify", arguments: [execPayload], home: scratch)
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("sessions/codex-deadbeef-0000-0000-0000-000000000000.json").path))
}

@Test func codexNotifyChainsSavedCommandWithPayloadAppended() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let recorder = scratch.appendingPathComponent("record-notify")
    let recordedArguments = scratch.appendingPathComponent("recorded-arguments.json")
    let recordedDepth = scratch.appendingPathComponent("recorded-depth")
    let recordedCount = scratch.appendingPathComponent("recorded-count")
    try """
    #!/bin/sh
    jq -n --args '$ARGS.positional' -- "$@" > "$RECORDED_ARGUMENTS"
    printf '%s\n' "${VIBENOTCH_NOTIFY_DEPTH:-unset}" > "$RECORDED_DEPTH"
    recorded_count=0
    [ ! -f "$RECORDED_COUNT" ] || recorded_count=$(cat "$RECORDED_COUNT")
    recorded_count=$((recorded_count + 1))
    printf '%s\n' "$recorded_count" > "$RECORDED_COUNT"
    """.write(to: recorder, atomically: true, encoding: .utf8)
    try makeExecutable(recorder)

    let chain = [recorder.path, "turn-ended", "argument with spaces"]
    let chainData = try JSONSerialization.data(withJSONObject: chain)
    try chainData.write(to: scratch.appendingPathComponent("codex-notify-chain.json"))

    let payload = #"{"type":"unknown-but-still-chained","value":"payload value"}"#
    let result = try runCodexScript(
        "vibenotch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: [
            "RECORDED_ARGUMENTS": recordedArguments.path,
            "RECORDED_DEPTH": recordedDepth.path,
            "RECORDED_COUNT": recordedCount.path,
        ]
    )

    #expect(result.status == 0)
    let data = try Data(contentsOf: recordedArguments)
    let arguments = try #require(JSONSerialization.jsonObject(with: data) as? [String])
    #expect(arguments == ["turn-ended", "argument with spaces", payload])
    #expect(try String(contentsOf: recordedDepth, encoding: .utf8) == "1\n")
    #expect(try String(contentsOf: recordedCount, encoding: .utf8) == "1\n")
}

@Test func codexShimEmitsWorkingThenRemovesAndPreservesExitStatus() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let fakeBin = scratch.appendingPathComponent("fake-bin", isDirectory: true)
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let fakeCodex = fakeBin.appendingPathComponent("codex")
    let recordedArguments = scratch.appendingPathComponent("fake-codex-arguments.json")
    try """
    #!/bin/sh
    jq -n --args '$ARGS.positional' -- "$@" > "$FAKE_CODEX_ARGUMENTS"
    sleep 1
    exit 7
    """.write(to: fakeCodex, atomically: true, encoding: .utf8)
    try makeExecutable(fakeCodex)

    let process = Process()
    process.executableURL = codexRepoRoot().appendingPathComponent("scripts/codex-shim")
    process.arguments = ["--model", "gpt-test", "prompt with spaces"]
    var environment = cleanCodexEnvironment(home: scratch)
    environment["PATH"] = "\(codexRepoRoot().appendingPathComponent("scripts").path):\(fakeBin.path):/usr/bin:/bin"
    environment["FAKE_CODEX_ARGUMENTS"] = recordedArguments.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    let sessionID = "codex-\(process.processIdentifier)"
    let sessionURL = scratch.appendingPathComponent("sessions/\(sessionID).json")
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: sessionURL.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }

    let working = try codexPayload(id: sessionID, home: scratch)
    #expect(working["status"] as? String == "working")
    #expect(working["source"] as? String == "codex")
    #expect(working["agent"] as? String == "codex")

    process.waitUntilExit()
    #expect(process.terminationStatus == 7)
    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))

    let argumentData = try Data(contentsOf: recordedArguments)
    let arguments = try #require(JSONSerialization.jsonObject(with: argumentData) as? [String])
    #expect(arguments == ["--model", "gpt-test", "prompt with spaces"])
}

@Test func codexInstallerDoesNotChainItsOwnPreRenameNotifier() throws {
    // On upgrade `notify` points at OUR old notifier. Adopting it as "someone
    // else's notifier" would keep the obsolete wrapper running forever,
    // writing into a spool the app no longer reads.
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )
    try #"notify = ["/Users/x/.notch-hud/bin/notch-codex-notify"]"#
        .write(to: config, atomically: true, encoding: .utf8)

    #expect(try runInstaller(home: home, prefix: prefix, config: config).status == 0)

    #expect(!FileManager.default.fileExists(
        atPath: prefix.appendingPathComponent("codex-notify-chain.json").path
    ))
    let text = try String(contentsOf: config, encoding: .utf8)
    #expect(!text.contains(".notch-hud/bin/notch-codex-notify"))
    #expect(text.contains("vibenotch-codex-notify"))
}

@Test func codexInstallerKeepsAThirdPartyNotifierWhileDroppingOurOwn() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )
    try #"notify = ["/Users/x/.notch-hud/bin/notch-codex-notify", "/opt/theirs/notify"]"#
        .write(to: config, atomically: true, encoding: .utf8)

    #expect(try runInstaller(home: home, prefix: prefix, config: config).status == 0)

    let chainData = try Data(
        contentsOf: prefix.appendingPathComponent("codex-notify-chain.json")
    )
    let chain = try #require(JSONSerialization.jsonObject(with: chainData) as? [String])
    #expect(chain == ["/opt/theirs/notify"])
}

@Test func codexInstallerIsIdempotentAndPreservesExistingNotifyChain() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "export PATH=/usr/bin\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    let skyNotify = #"["/Applications/Codex Computer Use.app/Client", "turn-ended"]"#
    let original = "model = \"gpt-test\"\nnotify = \(skyNotify)\napproval_policy = \"on-request\"\n"
    try original.write(to: config, atomically: true, encoding: .utf8)

    let first = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(first.status == 0)
    #expect(first.output.contains("bin files: changed"))
    #expect(first.output.contains("Codex notify config: changed"))
    #expect(first.output.contains("zsh PATH shim: changed"))

    for filename in ["vibenotch-emit", "vibenotch-codex-notify", "codex"] {
        #expect(FileManager.default.isExecutableFile(atPath: prefix.appendingPathComponent("bin/\(filename)").path))
    }

    let notifyTarget = prefix.appendingPathComponent("bin/vibenotch-codex-notify").path
    let expectedConfig = "model = \"gpt-test\"\nnotify = [\(jsonString(notifyTarget))]\napproval_policy = \"on-request\"\n"
    #expect(try String(contentsOf: config, encoding: .utf8) == expectedConfig)

    let chainData = try Data(contentsOf: prefix.appendingPathComponent("codex-notify-chain.json"))
    let savedChain = try #require(JSONSerialization.jsonObject(with: chainData) as? [String])
    #expect(savedChain == ["/Applications/Codex Computer Use.app/Client", "turn-ended"])

    let backupsAfterFirst = try backupNames(nextTo: config)
    #expect(backupsAfterFirst.count == 1)
    let zshBackupsAfterFirst = try backupNames(nextTo: home.appendingPathComponent(".zshrc"))
    #expect(zshBackupsAfterFirst.count == 1)

    let second = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(second.status == 0)
    #expect(second.output.contains("bin files: skipped"))
    #expect(second.output.contains("Codex notify config: skipped"))
    #expect(second.output.contains("zsh PATH shim: skipped"))
    #expect(try backupNames(nextTo: config) == backupsAfterFirst)
    #expect(try backupNames(nextTo: home.appendingPathComponent(".zshrc")) == zshBackupsAfterFirst)

    // The updater invokes this same reconciler after replacing the release.
    // Simulate an old installed wrapper, then run update reconciliation twice.
    try "#!/bin/sh\nexit 0\n".write(
        to: prefix.appendingPathComponent("bin/vibenotch-codex-notify"),
        atomically: true,
        encoding: .utf8
    )
    let third = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(third.status == 0)
    #expect(third.output.contains("bin files: changed"))
    #expect(third.output.contains("Codex notify config: skipped"))
    #expect(try Data(contentsOf: prefix.appendingPathComponent("codex-notify-chain.json")) == chainData)
    #expect(try backupNames(nextTo: config) == backupsAfterFirst)
    let prefixNames = try FileManager.default.contentsOfDirectory(atPath: prefix.path)
    #expect(!prefixNames.contains { $0.contains("codex-notify-chain.json.tmp.") })

    let configWithoutNotify = scratch.appendingPathComponent("codex/no-notify.toml")
    let noNotifyOriginal = "model = \"gpt-test\"\napproval_policy = \"never\"\n"
    try noNotifyOriginal.write(to: configWithoutNotify, atomically: true, encoding: .utf8)
    let appendRun = try runInstaller(home: home, prefix: prefix, config: configWithoutNotify)
    #expect(appendRun.status == 0)
    let appended = try String(contentsOf: configWithoutNotify, encoding: .utf8)
    #expect(appended.hasPrefix(noNotifyOriginal))
    #expect(appended.contains("notify = [\(jsonString(notifyTarget))]"))
}

@Test func codexInstallerRepairsComputerUsePreviousNotifyCycle() throws {
    // Exact production failure, bounded by the fake Computer Use client after
    // its second invocation: current Vibenotch adopts Computer Use as its
    // saved chain even though Computer Use already delegates back to
    // Vibenotch through --previous-notify. That produces
    // Vibenotch -> Computer Use -> Vibenotch -> Computer Use.
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed Vibenotch", isDirectory: true)
    let config = scratch.appendingPathComponent("codex config/config.toml")
    let computerUse = scratch.appendingPathComponent(
        "Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    )
    let computerUseCount = scratch.appendingPathComponent("computer-use-count")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: computerUse.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )
    try """
    #!/bin/sh
    payload=
    previous_notify=
    for argument do payload=$argument; done
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--previous-notify" ]; then
            shift
            previous_notify=${1:-}
            break
        fi
        shift
    done

    count=0
    [ ! -f "$COMPUTER_USE_COUNT_FILE" ] || count=$(cat "$COMPUTER_USE_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$COMPUTER_USE_COUNT_FILE"
    # Finite reproduction: prove the second Computer Use process happened,
    # then stop instead of recreating the machine-wide fork storm.
    [ "$count" -lt 2 ] || exit 0

    previous_arguments=$(printf '%s\n' "$previous_notify" | jq -r '
        if type == "array" and length > 0 and all(.[]; type == "string")
        then @sh else empty end
    ' 2>/dev/null)
    [ -n "$previous_arguments" ] || exit 0
    eval "set -- $previous_arguments"
    "$@" "$payload"
    """.write(to: computerUse, atomically: true, encoding: .utf8)
    try makeExecutable(computerUse)

    let notifyTarget = prefix.appendingPathComponent("bin/vibenotch-codex-notify").path
    let previousNotify = jsonArray([notifyTarget])
    let circularCommand = [
        computerUse.path,
        "turn-ended",
        "--previous-notify",
        previousNotify,
    ]
    let originalConfig = "notify = \(jsonArray(circularCommand))\n"
    try originalConfig.write(to: config, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: circularCommand).write(
        to: prefix.appendingPathComponent("codex-notify-chain.json"),
        options: .atomic
    )

    let install = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(install.status == 0)

    let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"12345678-abcd","cwd":"/tmp/project"}"#
    let notification = try runConfiguredNotify(
        config: config,
        payload: payload,
        home: home,
        prefix: prefix,
        extraEnvironment: ["COMPUTER_USE_COUNT_FILE": computerUseCount.path]
    )
    #expect(notification.status == 0)

    let count = Int((try? String(contentsOf: computerUseCount, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0")
    #expect(count == 1)
    let envelope = try codexPayload(id: "codex-app-12345678", home: prefix)
    #expect(envelope["seq"] as? Int == 1)
    #expect(try String(contentsOf: config, encoding: .utf8) ==
        "notify = [\(jsonString(notifyTarget))]\n")
    let repairedData = try Data(
        contentsOf: prefix.appendingPathComponent("codex-notify-chain.json")
    )
    let repairedChain = try #require(
        JSONSerialization.jsonObject(with: repairedData) as? [String]
    )
    #expect(repairedChain == [computerUse.path, "turn-ended"])
    #expect(install.output.contains("circular --previous-notify"))
}

@Test func codexInstallerMigratesAlreadyInstalledCircularChain() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed Vibenotch", isDirectory: true)
    let config = scratch.appendingPathComponent("codex config/config.toml")
    let computerUse = scratch.appendingPathComponent("Computer Use.app/Contents/MacOS/Client")
    let called = scratch.appendingPathComponent("computer-use-called")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: computerUse.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )
    try """
    #!/bin/sh
    printf 'called\n' > "$COMPUTER_USE_CALLED"
    """.write(to: computerUse, atomically: true, encoding: .utf8)
    try makeExecutable(computerUse)

    let notifyTarget = prefix.appendingPathComponent("bin/vibenotch-codex-notify").path
    try "notify = [\(jsonString(notifyTarget))]\n".write(
        to: config, atomically: true, encoding: .utf8
    )
    let circular = [
        computerUse.path,
        "turn-ended",
        "--previous-notify",
        jsonArray([notifyTarget]),
    ]
    try JSONSerialization.data(withJSONObject: circular).write(
        to: prefix.appendingPathComponent("codex-notify-chain.json"), options: .atomic
    )

    let first = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(first.status == 0)
    #expect(first.output.contains("circular --previous-notify"))
    let repairedBytes = try Data(
        contentsOf: prefix.appendingPathComponent("codex-notify-chain.json")
    )
    let repaired = try #require(JSONSerialization.jsonObject(with: repairedBytes) as? [String])
    #expect(repaired == [computerUse.path, "turn-ended"])

    let second = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(second.status == 0)
    #expect(second.output.contains("Codex notify config: skipped"))
    #expect(!second.output.contains("circular --previous-notify"))
    #expect(try Data(
        contentsOf: prefix.appendingPathComponent("codex-notify-chain.json")
    ) == repairedBytes)

    let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"migrate1-abcd"}"#
    let notification = try runConfiguredNotify(
        config: config,
        payload: payload,
        home: home,
        prefix: prefix,
        extraEnvironment: ["COMPUTER_USE_CALLED": called.path]
    )
    #expect(notification.status == 0)
    #expect(try String(contentsOf: called, encoding: .utf8) == "called\n")
    #expect(try codexPayload(id: "codex-app-migrate1", home: prefix)["seq"] as? Int == 1)
}

@Test func codexInstallerRecursivelySanitizesNestedPreviousNotify() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )

    let notifyTarget = prefix.appendingPathComponent("bin/vibenotch-codex-notify").path
    let inner = [
        "/Applications/Inner Notifier.app/Client",
        "inner argument",
        "--previous-notify",
        jsonArray([notifyTarget]),
    ]
    let outer = [
        "/Applications/Outer Notifier.app/Client",
        "turn-ended",
        "--previous-notify",
        jsonArray(inner),
        "ordinary-argument",
        notifyTarget, // mentioning the path as data is not itself a callback
    ]
    try "notify = \(jsonArray(outer))\n".write(
        to: config, atomically: true, encoding: .utf8
    )

    let install = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(install.status == 0)
    #expect(install.output.contains("circular --previous-notify"))
    let data = try Data(contentsOf: prefix.appendingPathComponent("codex-notify-chain.json"))
    let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String])
    #expect(saved.count == 6)
    #expect(saved[0] == outer[0])
    #expect(saved[1] == "turn-ended")
    #expect(saved[2] == "--previous-notify")
    let nestedData = try #require(saved[3].data(using: .utf8))
    let nested = try #require(JSONSerialization.jsonObject(with: nestedData) as? [String])
    #expect(nested == ["/Applications/Inner Notifier.app/Client", "inner argument"])
    #expect(Array(saved.suffix(2)) == ["ordinary-argument", notifyTarget])
}

@Test func codexInstallerBlocksEnvLauncherBackToVibenotch() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed with spaces", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )

    let notifyTarget = prefix.appendingPathComponent("bin/vibenotch-codex-notify").path
    let indirect = [
        "/usr/bin/env", "-i", "-S", "HOME=/Users/mac \(notifyTarget) turn-ended",
    ]
    try "notify = \(jsonArray(indirect))\n".write(
        to: config, atomically: true, encoding: .utf8
    )

    let install = try runInstaller(home: home, prefix: prefix, config: config)
    #expect(install.status == 0)
    #expect(install.output.contains("called Vibenotch recursively"))
    #expect(!FileManager.default.fileExists(
        atPath: prefix.appendingPathComponent("codex-notify-chain.json").path
    ))
    #expect(try String(contentsOf: config, encoding: .utf8) ==
        "notify = [\(jsonString(notifyTarget))]\n")
}

@Test func codexNotifyAndInstallerRejectMalformedChainJSON() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let home = scratch.appendingPathComponent("home", isDirectory: true)
    let prefix = scratch.appendingPathComponent("installed", isDirectory: true)
    let config = scratch.appendingPathComponent("codex/config.toml")
    let recorder = scratch.appendingPathComponent("must not run")
    let recorderMarker = scratch.appendingPathComponent("recorder-ran")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try "export PATH=/usr/bin\n".write(
        to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8
    )
    try "#!/bin/sh\nprintf ran > \"$RECORDER_MARKER\"\n".write(
        to: recorder, atomically: true, encoding: .utf8
    )
    try makeExecutable(recorder)

    let notifyTarget = prefix.appendingPathComponent("bin/vibenotch-codex-notify").path
    try "notify = [\(jsonString(notifyTarget))]\n".write(
        to: config, atomically: true, encoding: .utf8
    )
    let invalidDocuments = [
        "",
        "{",
        "null",
        "{}",
        "[]",
        "[\"\"]",
        "[\(jsonString(recorder.path)), 7]",
    ]

    let chain = prefix.appendingPathComponent("codex-notify-chain.json")
    for (index, document) in invalidDocuments.enumerated() {
        try Data(document.utf8).write(to: chain, options: .atomic)
        let runtime = try runCodexScript(
            "vibenotch-codex-notify",
            arguments: [#"{"type":"unrelated"}"#],
            home: prefix,
            extraEnvironment: ["RECORDER_MARKER": recorderMarker.path]
        )
        #expect(runtime.status == 0)
        #expect(runtime.output.contains("blocked invalid or circular"))
        #expect(!FileManager.default.fileExists(atPath: recorderMarker.path))

        // Recreate the same bad document and prove every install/update repairs it.
        try Data(document.utf8).write(to: chain, options: .atomic)
        let install = try runInstaller(home: home, prefix: prefix, config: config)
        #expect(install.status == 0, "invalid JSON case \(index)")
        #expect(install.output.contains("removed an invalid or circular"))
        #expect(!FileManager.default.fileExists(atPath: chain.path))
    }
}

@Test func codexNotifyDepthGuardBlocksOpaqueIndirectCycle() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let relay = scratch.appendingPathComponent("opaque relay with spaces")
    let relayMarker = scratch.appendingPathComponent("relay-called")
    try """
    #!/bin/sh
    payload=
    for argument do payload=$argument; done
    printf 'called\n' > "$RELAY_MARKER"
    unset VIBENOTCH_NOTIFY_DEPTH
    "$VIBENOTCH_NOTIFY_TARGET" "$payload"
    """.write(to: relay, atomically: true, encoding: .utf8)
    try makeExecutable(relay)
    try JSONSerialization.data(withJSONObject: [relay.path, "turn-ended"]).write(
        to: scratch.appendingPathComponent("codex-notify-chain.json"), options: .atomic
    )

    let target = codexRepoRoot().appendingPathComponent("scripts/vibenotch-codex-notify").path
    let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"depth001-abcd"}"#
    let first = try runCodexScript(
        "vibenotch-codex-notify",
        arguments: [payload],
        home: scratch,
        extraEnvironment: [
            "RELAY_MARKER": relayMarker.path,
            "VIBENOTCH_NOTIFY_TARGET": target,
        ]
    )
    #expect(first.status == 0)
    #expect(first.output.contains("blocked duplicate or recursive Codex notification"))
    #expect(try String(contentsOf: relayMarker, encoding: .utf8) == "called\n")
    #expect(try codexPayload(id: "codex-app-depth001", home: scratch)["seq"] as? Int == 1)

    let blockedPayload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"depth002-abcd"}"#
    let blocked = try runCodexScript(
        "vibenotch-codex-notify",
        arguments: [blockedPayload],
        home: scratch,
        extraEnvironment: ["VIBENOTCH_NOTIFY_DEPTH": "1"]
    )
    #expect(blocked.status == 0)
    #expect(blocked.output.contains("blocked recursive Codex notification at depth 1"))
    #expect(!FileManager.default.fileExists(
        atPath: scratch.appendingPathComponent("sessions/codex-app-depth002.json").path
    ))
}

@Test func codexNotifyRecoversAStaleGuardOwner() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"stale001-abcd"}"#
    let guardRoot = scratch.appendingPathComponent("codex-notify-guards", isDirectory: true)
    try FileManager.default.createDirectory(at: guardRoot, withIntermediateDirectories: true)
    let staleGuard = guardRoot.appendingPathComponent(
        "6512758a50e76be6d8fd43e9e82ee496904c7ee82ecc3fecdb840c07a06a2c5f.lock"
    )
    // shlock uses kill(pid, 0) and atomically replaces a dead owner's file.
    try "99999999\n".write(to: staleGuard, atomically: true, encoding: .utf8)
    // Its dot-lock algorithm deliberately waits for ctime to settle before
    // reclaiming, so it cannot mistake an in-progress atomic publication.
    Thread.sleep(forTimeInterval: 2.1)

    let result = try runCodexScript(
        "vibenotch-codex-notify", arguments: [payload], home: scratch
    )
    #expect(result.status == 0)
    #expect(try codexPayload(id: "codex-app-stale001", home: scratch)["seq"] as? Int == 1)
    #expect(try directoryEntryCount(guardRoot) == 0)
}

@Test func codexNotifySimulationStaysBoundedSequentiallyAndConcurrently() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let computerUse = scratch.appendingPathComponent(
        "Codex Computer Use.app/Contents/MacOS/Sky Computer Use Client"
    )
    let trace = scratch.appendingPathComponent("process trace", isDirectory: true)
    for directory in ["started", "ended", "active", "depth"] {
        try FileManager.default.createDirectory(
            at: trace.appendingPathComponent(directory), withIntermediateDirectories: true
        )
    }
    try FileManager.default.createDirectory(
        at: computerUse.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try """
    #!/bin/sh
    payload=
    for argument do payload=$argument; done
    identifier=$(printf '%s' "$payload" | jq -r '.["thread-id"]')
    active="$PROCESS_TRACE/active/$PPID"
    trap 'rm -f "$active"' EXIT HUP INT TERM
    : > "$active"
    printf '%s' "$payload" > "$PROCESS_TRACE/started/$identifier-$PPID.json"
    printf '%s' "${VIBENOTCH_NOTIFY_DEPTH:-unset}" > "$PROCESS_TRACE/depth/$identifier-$PPID"
    sleep 0.02
    printf '%s' "$payload" > "$PROCESS_TRACE/ended/$identifier-$PPID.json"
    rm -f "$active"
    trap - EXIT HUP INT TERM
    """.write(to: computerUse, atomically: true, encoding: .utf8)
    try makeExecutable(computerUse)
    let chainBytes = try JSONSerialization.data(
        withJSONObject: [computerUse.path, "turn-ended", "argument with spaces"]
    )
    let chain = scratch.appendingPathComponent("codex-notify-chain.json")
    try chainBytes.write(to: chain, options: .atomic)
    let environment = ["PROCESS_TRACE": trace.path]

    let sequentialCount = 5
    for index in 0..<sequentialCount {
        let identifier = String(format: "sim%05d", index)
        let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"\#(identifier)-abcd"}"#
        let result = try runCodexScript(
            "vibenotch-codex-notify", arguments: [payload], home: scratch,
            extraEnvironment: environment
        )
        #expect(result.status == 0)
        #expect(try directoryEntryCount(trace.appendingPathComponent("started")) == index + 1)
        #expect(try directoryEntryCount(trace.appendingPathComponent("ended")) == index + 1)
        #expect(try directoryEntryCount(trace.appendingPathComponent("active")) == 0)
    }

    let concurrentCount = 10
    var running: [(process: Process, output: Pipe)] = []
    for index in sequentialCount..<(sequentialCount + concurrentCount) {
        let identifier = String(format: "sim%05d", index)
        let payload = #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"\#(identifier)-abcd"}"#
        running.append(try launchCodexScript(
            "vibenotch-codex-notify", arguments: [payload], home: scratch,
            extraEnvironment: environment
        ))
    }
    for item in running {
        item.process.waitUntilExit()
        _ = item.output.fileHandleForReading.readDataToEndOfFile()
        #expect(item.process.terminationStatus == 0)
    }

    let total = sequentialCount + concurrentCount
    #expect(try directoryEntryCount(trace.appendingPathComponent("started")) == total)
    #expect(try directoryEntryCount(trace.appendingPathComponent("ended")) == total)
    #expect(try directoryEntryCount(trace.appendingPathComponent("depth")) == total)
    #expect(try directoryEntryCount(trace.appendingPathComponent("active")) == 0)
    #expect(try directoryEntryCount(
        scratch.appendingPathComponent("codex-notify-guards")
    ) == 0)
    #expect(try Data(contentsOf: chain) == chainBytes)

    let depthFiles = try FileManager.default.contentsOfDirectory(
        at: trace.appendingPathComponent("depth"),
        includingPropertiesForKeys: nil
    )
    for file in depthFiles {
        #expect(try String(contentsOf: file, encoding: .utf8) == "1")
    }
    for index in 0..<total {
        let identifier = String(format: "sim%05d", index)
        let envelope = try codexPayload(id: "codex-app-\(identifier)", home: scratch)
        #expect(envelope["seq"] as? Int == 1)
        #expect(envelope["status"] as? String == "done")
    }
}

@Test func codexNotifyDoesNotSerializeDistinctCksumCollisionPayloads() throws {
    let scratch = try makeCodexScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let notifier = scratch.appendingPathComponent("previous notifier")
    let trace = scratch.appendingPathComponent("collision trace", isDirectory: true)
    try FileManager.default.createDirectory(at: trace, withIntermediateDirectories: true)
    try """
    #!/bin/sh
    printf 'started\n' > "$COLLISION_TRACE/$PPID"
    sleep 0.15
    """.write(to: notifier, atomically: true, encoding: .utf8)
    try makeExecutable(notifier)
    try JSONSerialization.data(withJSONObject: [notifier.path, "turn-ended"]).write(
        to: scratch.appendingPathComponent("codex-notify-chain.json"), options: .atomic
    )

    // These valid, distinct payloads have the same POSIX cksum and length.
    // A CRC-based guard drops one while the SHA-256 guard lets both run.
    let payloads = [
        #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"82228208fc7b48e9-abcd"}"#,
        #"{"type":"agent-turn-complete","client":"Codex Desktop","thread-id":"de0be066f66464e8-abcd"}"#,
    ]
    var running: [(process: Process, output: Pipe)] = []
    for payload in payloads {
        running.append(try launchCodexScript(
            "vibenotch-codex-notify",
            arguments: [payload],
            home: scratch,
            extraEnvironment: ["COLLISION_TRACE": trace.path]
        ))
    }
    for item in running {
        item.process.waitUntilExit()
        _ = item.output.fileHandleForReading.readDataToEndOfFile()
        #expect(item.process.terminationStatus == 0)
    }

    #expect(try directoryEntryCount(trace) == 2)
    #expect(try codexPayload(id: "codex-app-82228208", home: scratch)["seq"] as? Int == 1)
    #expect(try codexPayload(id: "codex-app-de0be066", home: scratch)["seq"] as? Int == 1)
    #expect(try directoryEntryCount(
        scratch.appendingPathComponent("codex-notify-guards")
    ) == 0)
}

private func codexRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeCodexScratch() throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("notch-codex-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
}

private func cleanCodexEnvironment(home: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["VIBENOTCH_HOME"] = home.path
    // These tests often run from inside the Codex shim itself. Inheriting its
    // session makes desktop notifications take the CLI update-only branch and
    // makes otherwise isolated fixtures depend on the parent process's id.
    environment["NOTCH_CODEX_SESSION_ID"] = nil
    environment["VIBENOTCH_SHIM_DEPTH"] = nil
    environment["VIBENOTCH_NOTIFY_DEPTH"] = nil
    environment["VIBENOTCH_TTY"] = ""
    environment["TERM_PROGRAM"] = nil
    environment["ITERM_SESSION_ID"] = nil
    environment["WEZTERM_PANE"] = nil
    environment["KITTY_WINDOW_ID"] = nil
    environment["WINDOWID"] = nil
    return environment
}

private func runCodexScript(
    _ name: String,
    arguments: [String],
    home: URL,
    extraEnvironment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
    let running = try launchCodexScript(
        name,
        arguments: arguments,
        home: home,
        extraEnvironment: extraEnvironment
    )
    running.process.waitUntilExit()
    let data = running.output.fileHandleForReading.readDataToEndOfFile()
    return (running.process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func launchCodexScript(
    _ name: String,
    arguments: [String],
    home: URL,
    extraEnvironment: [String: String] = [:]
) throws -> (process: Process, output: Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [codexRepoRoot().appendingPathComponent("scripts/\(name)").path] + arguments
    var environment = cleanCodexEnvironment(home: home)
    for (key, value) in extraEnvironment {
        environment[key] = value
    }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    return (process, output)
}

private func runInstaller(home: URL, prefix: URL, config: URL) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [codexRepoRoot().appendingPathComponent("scripts/install-codex-adapter.sh").path]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["VIBENOTCH_INSTALL_PREFIX"] = prefix.path
    environment["VIBENOTCH_CODEX_CONFIG"] = config.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func codexPayload(id: String, home: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent("sessions/\(id).json"))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func makeExecutable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

private func jsonString(_ value: String) -> String {
    let data = try! JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
}

private func jsonArray(_ value: [String]) -> String {
    let data = try! JSONSerialization.data(
        withJSONObject: value,
        options: [.withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
}

private func runConfiguredNotify(
    config: URL,
    payload: String,
    home: URL,
    prefix: URL,
    extraEnvironment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
    let text = try String(contentsOf: config, encoding: .utf8)
    let line = try #require(text.split(separator: "\n").first { row in
        row.trimmingCharacters(in: .whitespaces).hasPrefix("notify =")
    })
    let value = line.split(separator: "=", maxSplits: 1)[1]
        .trimmingCharacters(in: .whitespaces)
    let data = try #require(value.data(using: .utf8))
    let command = try #require(JSONSerialization.jsonObject(with: data) as? [String])
    let executable = try #require(command.first)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(command.dropFirst()) + [payload]
    var environment = cleanCodexEnvironment(home: home)
    environment["VIBENOTCH_HOME"] = prefix.path
    for (key, value) in extraEnvironment {
        environment[key] = value
    }
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: outputData, as: UTF8.self))
}

private func backupNames(nextTo file: URL) throws -> [String] {
    let prefix = file.lastPathComponent + ".bak."
    return try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        .filter { $0.hasPrefix(prefix) }
        .sorted()
}

private func directoryEntryCount(_ directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).count
}
