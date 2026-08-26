import Foundation
import Testing

@Test func claudeHooksInstallerAddsHooksAdditivelyAndIsIdempotent() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let settings = scratch.appendingPathComponent("claude/settings.json")
    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)

    let existing = """
    {
      "permissions": { "defaultMode": "auto" },
      "hooks": {
        "PreToolUse": [
          { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
        ]
      }
    }
    """
    try existing.write(to: settings, atomically: true, encoding: .utf8)

    let first = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(first.status == 0)
    #expect(first.output.contains("changed"))

    let afterFirst = try Data(contentsOf: settings)
    let json = try #require(JSONSerialization.jsonObject(with: afterFirst) as? [String: Any])

    // Unrelated top-level + unrelated hook entry both survive untouched.
    let permissions = try #require(json["permissions"] as? [String: Any])
    #expect(permissions["defaultMode"] as? String == "auto")

    let hooks = try #require(json["hooks"] as? [String: Any])
    let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(preToolUse.count == 2)
    #expect(preToolUse.contains { ($0["matcher"] as? String) == "Bash" })

    let hookPath = prefix.appendingPathComponent("bin/vibenotch-claude-hook").path
    let ourGroup = try #require(preToolUse.first { ($0["matcher"] as? String) == "*" })
    let ourGroupHooks = try #require(ourGroup["hooks"] as? [[String: Any]])
    #expect(ourGroupHooks.first?["command"] as? String == "\(hookPath) tool")

    let expected: [(event: String, verb: String)] = [
        ("UserPromptSubmit", "working"),
        ("Stop", "done"),
        ("Notification", "notify"),
        ("SessionEnd", "remove"),
    ]
    for (event, verb) in expected {
        let entries = try #require(hooks[event] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["matcher"] == nil)
        let entryHooks = try #require(entries[0]["hooks"] as? [[String: Any]])
        #expect(entryHooks.first?["command"] as? String == "\(hookPath) \(verb)")
    }

    let backupsAfterFirst = try claudeHooksBackupNames(nextTo: settings)
    #expect(backupsAfterFirst.count == 1)

    let statusLine = try #require(json["statusLine"] as? [String: Any])
    #expect(statusLine["type"] as? String == "command")
    #expect((statusLine["command"] as? String)?.contains("vibenotch-claude-statusline") == true)

    let chain = try claudeStatuslineChain(prefix: prefix)
    #expect(chain["schema_version"] as? Int == 1)
    #expect(chain["present"] as? Bool == false)
    let chainAfterFirst = try Data(contentsOf: claudeStatuslineChainURL(prefix: prefix))

    let second = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(second.status == 0)
    #expect(second.output.contains("skipped"))
    #expect(try Data(contentsOf: settings) == afterFirst)
    #expect(try claudeHooksBackupNames(nextTo: settings) == backupsAfterFirst)
    #expect(try Data(contentsOf: claudeStatuslineChainURL(prefix: prefix)) == chainAfterFirst)
}

@Test func claudeHooksInstallerCreatesSettingsWhenMissing() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let settings = scratch.appendingPathComponent("claude/settings.json")
    #expect(!FileManager.default.fileExists(atPath: settings.path))

    let result = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(result.status == 0)
    #expect(FileManager.default.fileExists(atPath: settings.path))
    #expect(try claudeHooksBackupNames(nextTo: settings).isEmpty)

    let json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    )
    let hooks = try #require(json["hooks"] as? [String: Any])
    #expect((hooks["PreToolUse"] as? [[String: Any]])?.count == 1)
    #expect(json["statusLine"] != nil)
}

@Test func claudeHooksInstallerUninstallRemovesOnlyOurEntries() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed-vibenotch", isDirectory: true)
    let settings = scratch.appendingPathComponent("claude/settings.json")
    try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "hooks": {
        "PreToolUse": [
          { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
        ]
      }
    }
    """.write(to: settings, atomically: true, encoding: .utf8)

    _ = try runClaudeHooksInstaller(prefix: prefix, settings: settings)

    let result = try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true)
    #expect(result.status == 0)
    #expect(result.output.contains("changed"))

    let json = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
    )
    let hooks = try #require(json["hooks"] as? [String: Any])
    let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
    #expect(preToolUse.count == 1)
    #expect(preToolUse[0]["matcher"] as? String == "Bash")
    #expect(hooks["UserPromptSubmit"] == nil)
    #expect(json["statusLine"] == nil)
    #expect(!FileManager.default.fileExists(atPath: claudeStatuslineChainURL(prefix: prefix).path))

    // Idempotent: nothing left to remove on a second uninstall.
    let second = try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true)
    #expect(second.status == 0)
    #expect(second.output.contains("skipped"))
}

@Test func claudeHooksUninstallLeavesAForeignSettingsFileByteForByte() throws {
    // Re-serializing on a no-op rewrote a hand-formatted settings.json and
    // reported "changed", so an uninstall with nothing of ours to remove still
    // reflowed the user's file and left a backup behind.
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let settings = scratch.appendingPathComponent("settings.json")
    let original = """
    {
        "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "rtk hook claude"}]}]},
            "otherKey": 1
    }
    """
    try original.write(to: settings, atomically: true, encoding: .utf8)

    let result = try runClaudeHooksInstaller(
        prefix: scratch.appendingPathComponent("prefix"),
        settings: settings,
        uninstall: true
    )

    #expect(result.status == 0)
    #expect(result.output.contains("skipped"))
    #expect(try String(contentsOf: settings, encoding: .utf8) == original)
    #expect(try claudeHooksBackupNames(nextTo: settings).isEmpty)
}

@Test func claudeHooksInstallerRemovesThePreRenameNotchHUDEntries() throws {
    // Upgrading users still have the old hooks pointing at ~/.notch-hud, whose
    // spool the app no longer reads: left in place every session gets written
    // twice, once into a directory nobody watches.
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let settings = scratch.appendingPathComponent("settings.json")
    try """
    {"hooks": {
      "Stop": [{"hooks": [{"type": "command", "command": "/Users/x/.notch-hud/bin/notch-claude-hook done"}]}],
      "PreToolUse": [
        {"matcher": "*", "hooks": [{"type": "command", "command": "/Users/x/.notch-hud/bin/notch-claude-hook tool"}]},
        {"matcher": "*", "hooks": [{"type": "command", "command": "rtk hook claude"}]}
      ]
    }}
    """.write(to: settings, atomically: true, encoding: .utf8)

    let result = try runClaudeHooksInstaller(
        prefix: scratch.appendingPathComponent("prefix"),
        settings: settings,
        uninstall: false
    )
    #expect(result.status == 0)

    let text = try String(contentsOf: settings, encoding: .utf8)
    #expect(!text.contains(".notch-hud/bin/notch-claude-hook"))
    #expect(text.contains("rtk hook claude"))
    #expect(text.contains("vibenotch-claude-hook done"))
    // The scratch directory name also contains "vibenotch-claude-hook", so count
    // the installed path specifically.
    #expect(text.components(separatedBy: "/bin/vibenotch-claude-hook").count - 1 == 5)
}

@Test func claudeHooksLegacyRemovalKeepsNeighbouringCommandsInTheSameEntry() throws {
    // One entry can hold several commands. Dropping the whole entry because
    // one of them is ours silently deletes the others.
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let settings = scratch.appendingPathComponent("settings.json")
    try """
    {"hooks": {"Stop": [{"hooks": [
      {"type": "command", "command": "/Users/x/.notch-hud/bin/notch-claude-hook done"},
      {"type": "command", "command": "say finished"}
    ]}]}}
    """.write(to: settings, atomically: true, encoding: .utf8)

    let result = try runClaudeHooksInstaller(
        prefix: scratch.appendingPathComponent("prefix"),
        settings: settings,
        uninstall: false
    )
    #expect(result.status == 0)

    let text = try String(contentsOf: settings, encoding: .utf8)
    #expect(!text.contains(".notch-hud/bin/notch-claude-hook"))
    #expect(text.contains("say finished"))
}

@Test func claudeStatuslinePreservesLegitimateCommandAndRestoresItOnUninstall() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let prefix = scratch.appendingPathComponent("installed Vibenotch 'quoted'", isDirectory: true)
    let settings = scratch.appendingPathComponent("Claude settings/settings.json")
    let prior = scratch.appendingPathComponent("prior scripts/prior 'status line'.sh")
    let count = scratch.appendingPathComponent("prior-count.txt")
    let received = scratch.appendingPathComponent("prior-payload.json")
    try FileManager.default.createDirectory(at: prior.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    #!/bin/sh
    cat > "$PRIOR_PAYLOAD_FILE"
    printf 'called\\n' >> "$PRIOR_COUNT_FILE"
    printf 'prior display'
    """.write(to: prior, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prior.path)

    let originalStatusLine: [String: Any] = [
        "type": "command",
        "command": shellQuote(prior.path),
        "padding": 7,
    ]
    try writeClaudeSettings(["statusLine": originalStatusLine, "unrelated": true], to: settings)
    let first = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(first.status == 0)
    let installed = try readJSONObject(settings)
    let installedStatusLine = try #require(installed["statusLine"] as? [String: Any])
    #expect(installedStatusLine["padding"] as? Int == 7)
    let installedCommand = try #require(installedStatusLine["command"] as? String)

    let chain = try claudeStatuslineChain(prefix: prefix)
    #expect(chain["present"] as? Bool == true)
    let saved = try #require(chain["status_line"] as? [String: Any])
    #expect(saved["command"] as? String == shellQuote(prior.path))
    #expect(saved["padding"] as? Int == 7)

    try installClaudeStatuslineRuntime(prefix: prefix)
    let reset = Int(Date().timeIntervalSince1970) + 3_600
    let resetISO = ISO8601DateFormatter().string(
        from: Date(timeIntervalSince1970: TimeInterval(reset))
    )
    let payload = #"{"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":\#(reset)},"seven_day":{"used_percentage":45,"resets_at":"\#(resetISO)"}},"credential":"must-not-be-cached"}"#
    let invocation = try runClaudeStatuslineCommand(
        installedCommand,
        home: prefix,
        payload: payload,
        extraEnvironment: [
            "PRIOR_COUNT_FILE": count.path,
            "PRIOR_PAYLOAD_FILE": received.path,
        ]
    )
    #expect(invocation.status == 0)
    #expect(invocation.output == "prior display")
    #expect(try String(contentsOf: count, encoding: .utf8) == "called\n")
    #expect(try String(contentsOf: received, encoding: .utf8) == payload)

    let cacheURL = prefix.appendingPathComponent("claude-usage.json")
    let cache = try readJSONObject(cacheURL)
    #expect(cache["schema_version"] as? Int == 1)
    #expect(cache["captured_at"] as? Int != nil)
    let rateLimits = try #require(cache["rate_limits"] as? [String: Any])
    let fiveHour = try #require(rateLimits["five_hour"] as? [String: Any])
    let sevenDay = try #require(rateLimits["seven_day"] as? [String: Any])
    #expect(fiveHour["used_percentage"] as? Double == 12.5)
    #expect(fiveHour["resets_at"] as? Int == reset)
    #expect(sevenDay["used_percentage"] as? Int == 45)
    #expect(sevenDay["resets_at"] as? Int == reset)
    #expect(!String(decoding: try Data(contentsOf: cacheURL), as: UTF8.self).contains("credential"))
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o777 == 0o600)

    let afterFirst = try Data(contentsOf: settings)
    let chainAfterFirst = try Data(contentsOf: claudeStatuslineChainURL(prefix: prefix))
    let backupsAfterFirst = try claudeHooksBackupNames(nextTo: settings)
    for _ in 0..<3 {
        let repeated = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
        #expect(repeated.status == 0)
        #expect(repeated.output.contains("skipped"))
    }
    #expect(try Data(contentsOf: settings) == afterFirst)
    #expect(try Data(contentsOf: claudeStatuslineChainURL(prefix: prefix)) == chainAfterFirst)
    #expect(try claudeHooksBackupNames(nextTo: settings) == backupsAfterFirst)

    let uninstall = try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true)
    #expect(uninstall.status == 0)
    let restored = try readJSONObject(settings)
    let restoredStatusLine = try #require(restored["statusLine"] as? [String: Any])
    #expect(restoredStatusLine["command"] as? String == originalStatusLine["command"] as? String)
    #expect(restoredStatusLine["padding"] as? Int == 7)
    #expect(restored["unrelated"] as? Bool == true)
    #expect(!FileManager.default.fileExists(atPath: claudeStatuslineChainURL(prefix: prefix).path))
}

@Test func claudeStatuslineRestoresAnExplicitNullValue() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let prefix = scratch.appendingPathComponent("prefix")
    let settings = scratch.appendingPathComponent("settings.json")
    try writeClaudeSettings(["statusLine": NSNull(), "keep": "yes"], to: settings)

    #expect(try runClaudeHooksInstaller(prefix: prefix, settings: settings).status == 0)
    let chain = try claudeStatuslineChain(prefix: prefix)
    #expect(chain["present"] as? Bool == true)
    #expect(chain["status_line"] is NSNull)

    #expect(try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true).status == 0)
    let restored = try readJSONObject(settings)
    #expect(restored["statusLine"] is NSNull)
    #expect(restored["keep"] as? String == "yes")
}

@Test func claudeStatuslineLeavesAnUnsupportedForeignShapeUntouched() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let prefix = scratch.appendingPathComponent("prefix")
    let settings = scratch.appendingPathComponent("settings.json")
    let foreign: [String: Any] = ["type": "future-provider", "value": "opaque"]
    try writeClaudeSettings(["statusLine": foreign, "keep": "yes"], to: settings)

    let result = try runClaudeHooksInstaller(prefix: prefix, settings: settings)

    #expect(result.status == 0)
    #expect(result.output.contains("left an unsupported existing configuration untouched"))
    let installed = try readJSONObject(settings)
    let statusLine = try #require(installed["statusLine"] as? [String: Any])
    #expect(statusLine["type"] as? String == "future-provider")
    #expect(statusLine["value"] as? String == "opaque")
    #expect(!FileManager.default.fileExists(atPath: claudeStatuslineChainURL(prefix: prefix).path))
    let hooks = try #require(installed["hooks"] as? [String: Any])
    #expect(hooks["Stop"] != nil)
}

@Test func claudeStatuslineInvalidPayloadNeverReplacesLastGoodCache() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let home = scratch.appendingPathComponent("Vibenotch home")
    let reset = Int(Date().timeIntervalSince1970) + 3_600
    let valid = #"{"rate_limits":{"five_hour":{"used_percentage":33,"resets_at":\#(reset)}}}"#
    #expect(try runClaudeStatusline(home: home, payload: valid).status == 0)
    let cache = home.appendingPathComponent("claude-usage.json")
    let lastGood = try Data(contentsOf: cache)

    for invalid in [
        "",
        "not-json",
        #"{"rate_limits":null}"#,
        #"{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":\#(reset)}}}"#,
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":"not-a-date"}}}"#,
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":9999999999999}}}"#,
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":\#(reset)},"seven_day":{"used_percentage":101,"resets_at":\#(reset)}}}"#,
        #"{"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":\#(reset)},"seven_day":null}}"#,
    ] {
        #expect(try runClaudeStatusline(home: home, payload: invalid).status == 0)
        #expect(try Data(contentsOf: cache) == lastGood)
    }
}

@Test func claudeStatuslineMigratesAnOldPrefixWithoutChainingIt() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let oldPrefix = scratch.appendingPathComponent("old prefix")
    let newPrefix = scratch.appendingPathComponent("new prefix")
    let settings = scratch.appendingPathComponent("settings.json")
    let oldBridge = oldPrefix.appendingPathComponent("bin/vibenotch-claude-statusline")
    try writeClaudeSettings(
        ["statusLine": ["type": "command", "command": shellQuote(oldBridge.path)]],
        to: settings
    )

    let migration = try runClaudeHooksInstaller(prefix: newPrefix, settings: settings)
    #expect(migration.status == 0)
    #expect(migration.output.contains("removed an obsolete or circular Vibenotch command"))
    let installed = try readJSONObject(settings)
    let statusLine = try #require(installed["statusLine"] as? [String: Any])
    let newBridge = newPrefix.appendingPathComponent("bin/vibenotch-claude-statusline")
    #expect(statusLine["command"] as? String == shellQuote(newBridge.path))
    let chain = try claudeStatuslineChain(prefix: newPrefix)
    #expect(chain["present"] as? Bool == false)

    #expect(try runClaudeHooksInstaller(prefix: newPrefix, settings: settings, uninstall: true).status == 0)
    #expect(try readJSONObject(settings)["statusLine"] == nil)
}

@Test func claudeStatuslineDoesNotMistakeATextualBridgeMentionForRecursion() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let prefix = scratch.appendingPathComponent("prefix")
    let settings = scratch.appendingPathComponent("settings.json")
    let previousCommand = "printf '%s' 'vibenotch-claude-statusline is only text'"
    try writeClaudeSettings(
        ["statusLine": ["type": "command", "command": previousCommand]],
        to: settings
    )

    #expect(try runClaudeHooksInstaller(prefix: prefix, settings: settings).status == 0)
    let installed = try readJSONObject(settings)
    let active = try #require(installed["statusLine"] as? [String: Any])
    let activeCommand = try #require(active["command"] as? String)
    let chain = try claudeStatuslineChain(prefix: prefix)
    let saved = try #require(chain["status_line"] as? [String: Any])
    #expect(saved["command"] as? String == previousCommand)

    try installClaudeStatuslineRuntime(prefix: prefix)
    let reset = Int(Date().timeIntervalSince1970) + 3_600
    let payload = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":\#(reset)}}}"#
    let invocation = try runClaudeStatuslineCommand(
        activeCommand,
        home: prefix,
        payload: payload
    )
    #expect(invocation.status == 0)
    #expect(invocation.output == "vibenotch-claude-statusline is only text")

    #expect(try runClaudeHooksInstaller(prefix: prefix, settings: settings, uninstall: true).status == 0)
    let restored = try readJSONObject(settings)
    let restoredStatusLine = try #require(restored["statusLine"] as? [String: Any])
    #expect(restoredStatusLine["command"] as? String == previousCommand)
}

@Test func claudeStatuslineConcurrentInvocationsLeaveOneCompleteAtomicCache() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let home = scratch.appendingPathComponent("concurrent home")

    let reset = Int(Date().timeIntervalSince1970) + 3_600
    var processes: [Process] = []
    for index in 0..<16 {
        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":\#(index),"resets_at":\#(reset)}}}"#
        processes.append(try startClaudeStatusline(home: home, payload: payload))
    }
    for process in processes {
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    let cache = try readJSONObject(home.appendingPathComponent("claude-usage.json"))
    let limits = try #require(cache["rate_limits"] as? [String: Any])
    let window = try #require(limits["five_hour"] as? [String: Any])
    let percentage = try #require(window["used_percentage"] as? Int)
    #expect((0..<16).contains(percentage))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path)
        .filter { $0.contains(".tmp.") }
    #expect(leftovers.isEmpty)
}

@Test func claudeStatuslineDepthGuardBlocksCacheAndPreviousCommand() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let home = scratch.appendingPathComponent("home")
    let marker = scratch.appendingPathComponent("prior-ran")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try writeJSON(
        [
            "schema_version": 1,
            "present": true,
            "status_line": ["type": "command", "command": "touch \(shellQuote(marker.path))"],
        ],
        to: home.appendingPathComponent("claude-statusline-chain.json")
    )

    let reset = Int(Date().timeIntervalSince1970) + 3_600
    let payload = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":\#(reset)}}}"#
    let result = try runClaudeStatusline(
        home: home,
        payload: payload,
        extraEnvironment: ["VIBENOTCH_STATUSLINE_DEPTH": "1"]
    )
    #expect(result.status == 0)
    #expect(result.output.contains("blocked recursive execution"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("claude-usage.json").path))
}

@Test func claudeStatuslineKernelGuardSurvivesAnUnsetDepthVariable() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let home = scratch.appendingPathComponent("home")
    let relay = scratch.appendingPathComponent("opaque relay.sh")
    let count = scratch.appendingPathComponent("relay-count.txt")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try """
    #!/bin/sh
    printf 'relay\\n' >> "$RELAY_COUNT"
    unset VIBENOTCH_STATUSLINE_DEPTH
    exec "$VIBENOTCH_REENTER"
    """.write(to: relay, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: relay.path)
    try writeJSON(
        [
            "schema_version": 1,
            "present": true,
            "status_line": ["type": "command", "command": shellQuote(relay.path)],
        ],
        to: home.appendingPathComponent("claude-statusline-chain.json")
    )

    let reset = Int(Date().timeIntervalSince1970) + 3_600
    let payload = #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":\#(reset)}}}"#
    let bridge = claudeHooksRepoRoot().appendingPathComponent("scripts/vibenotch-claude-statusline")
    let result = try runClaudeStatusline(
        home: home,
        payload: payload,
        extraEnvironment: [
            "RELAY_COUNT": count.path,
            "VIBENOTCH_REENTER": bridge.path,
        ]
    )

    #expect(result.status == 0)
    #expect(result.output.contains("blocked duplicate or recursive execution"))
    #expect(try String(contentsOf: count, encoding: .utf8) == "relay\n")
}

@Test func claudeHooksMalformedSettingsLeaveSettingsAndSidecarUntouched() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let prefix = scratch.appendingPathComponent("prefix")
    let settings = scratch.appendingPathComponent("settings.json")
    let malformed = Data(#"{"statusLine": "# .utf8)
    try malformed.write(to: settings)

    let result = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(result.status != 0)
    #expect(result.output.contains("not valid JSON"))
    #expect(try Data(contentsOf: settings) == malformed)
    #expect(!FileManager.default.fileExists(atPath: claudeStatuslineChainURL(prefix: prefix).path))
    #expect(try claudeHooksBackupNames(nextTo: settings).isEmpty)
}

@Test func claudeStatuslineReconciliationRepairsACircularSidecar() throws {
    let scratch = try makeClaudeHooksScratch()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let prefix = scratch.appendingPathComponent("prefix")
    let settings = scratch.appendingPathComponent("settings.json")
    #expect(try runClaudeHooksInstaller(prefix: prefix, settings: settings).status == 0)
    let afterInstall = try Data(contentsOf: settings)
    let backups = try claudeHooksBackupNames(nextTo: settings)

    try writeJSON(
        [
            "schema_version": 1,
            "present": true,
            "status_line": [
                "type": "command",
                "command": shellQuote(prefix.appendingPathComponent("bin/vibenotch-claude-statusline").path),
            ],
        ],
        to: claudeStatuslineChainURL(prefix: prefix)
    )

    let repair = try runClaudeHooksInstaller(prefix: prefix, settings: settings)
    #expect(repair.status == 0)
    #expect(repair.output.contains("removed a circular or malformed previous command"))
    #expect(try Data(contentsOf: settings) == afterInstall)
    #expect(try claudeHooksBackupNames(nextTo: settings) == backups)
    let repaired = try claudeStatuslineChain(prefix: prefix)
    #expect(repaired["present"] as? Bool == false)
}

@Test func claudeInstallIncludesStatuslineRuntimeInTheCopiedHelpers() throws {
    let install = try String(
        contentsOf: claudeHooksRepoRoot().appendingPathComponent("scripts/install.sh"),
        encoding: .utf8
    )
    #expect(install.contains("vibenotch-claude-hook vibenotch-claude-statusline vibenotch-codex-notify"))
    let runtimeInstall = try #require(install.range(of: "\ninstall_runtime_scripts\n"))
    let reconciliation = try #require(install.range(of: "\ninstall_claude_hooks_step\n"))
    #expect(runtimeInstall.lowerBound < reconciliation.lowerBound)
}

private func claudeHooksRepoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func makeClaudeHooksScratch() throws -> URL {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibenotch-claude-hooks-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
}

private func runClaudeHooksInstaller(
    prefix: URL,
    settings: URL,
    uninstall: Bool = false
) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    var arguments = [claudeHooksRepoRoot().appendingPathComponent("scripts/install-claude-hooks.sh").path]
    if uninstall {
        arguments.append("--uninstall")
    }
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["VIBENOTCH_INSTALL_PREFIX"] = prefix.path
    environment["VIBENOTCH_INSTALL_CLAUDE_SETTINGS"] = settings.path
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

private func claudeHooksBackupNames(nextTo file: URL) throws -> [String] {
    let prefix = file.lastPathComponent + ".bak."
    let directory = file.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(prefix) }
        .sorted()
}

private func claudeStatuslineChainURL(prefix: URL) -> URL {
    prefix.appendingPathComponent("claude-statusline-chain.json")
}

private func claudeStatuslineChain(prefix: URL) throws -> [String: Any] {
    try readJSONObject(claudeStatuslineChainURL(prefix: prefix))
}

private func readJSONObject(_ url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func writeJSON(_ value: Any, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}

private func writeClaudeSettings(_ value: [String: Any], to url: URL) throws {
    try writeJSON(value, to: url)
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

private func installClaudeStatuslineRuntime(prefix: URL) throws {
    let source = claudeHooksRepoRoot().appendingPathComponent("scripts/vibenotch-claude-statusline")
    let destination = prefix.appendingPathComponent("bin/vibenotch-claude-statusline")
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: source, to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
}

private func runClaudeStatusline(
    home: URL,
    payload: String,
    extraEnvironment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
    let command = shellQuote(
        claudeHooksRepoRoot().appendingPathComponent("scripts/vibenotch-claude-statusline").path
    )
    return try runClaudeStatuslineCommand(
        command,
        home: home,
        payload: payload,
        extraEnvironment: extraEnvironment
    )
}

private func runClaudeStatuslineCommand(
    _ command: String,
    home: URL,
    payload: String,
    extraEnvironment: [String: String] = [:]
) throws -> (status: Int32, output: String) {
    let process = try startClaudeStatuslineCommand(
        command,
        home: home,
        payload: payload,
        extraEnvironment: extraEnvironment
    )
    process.process.waitUntilExit()
    let data = process.output.fileHandleForReading.readDataToEndOfFile()
    return (process.process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func startClaudeStatusline(home: URL, payload: String) throws -> Process {
    let command = shellQuote(
        claudeHooksRepoRoot().appendingPathComponent("scripts/vibenotch-claude-statusline").path
    )
    return try startClaudeStatuslineCommand(command, home: home, payload: payload).process
}

private func startClaudeStatuslineCommand(
    _ command: String,
    home: URL,
    payload: String,
    extraEnvironment: [String: String] = [:]
) throws -> (process: Process, output: Pipe) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var environment = ProcessInfo.processInfo.environment
    environment["VIBENOTCH_HOME"] = home.path
    for (key, value) in extraEnvironment {
        environment[key] = value
    }
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(Data(payload.utf8))
    try input.fileHandleForWriting.close()
    return (process, output)
}
