import Foundation
import Testing
@testable import Vibenotch

@Test func legacyDefaultsAreAdoptedWithoutOverwritingNewerValues() throws {
    let legacyName = "LegacyMigrationTests.legacy.\(UUID().uuidString)"
    let currentName = "LegacyMigrationTests.current.\(UUID().uuidString)"
    let legacy = try #require(UserDefaults(suiteName: legacyName))
    let current = try #require(UserDefaults(suiteName: currentName))
    defer {
        legacy.removePersistentDomain(forName: legacyName)
        current.removePersistentDomain(forName: currentName)
    }

    legacy.set(Data([1, 2, 3]), forKey: "keepAwake.config")
    legacy.set(7, forKey: "remoteBridge.lastAppliedSettingsRev")
    legacy.set("https://old.example", forKey: "remoteBridge.pairedRemoteURL")
    // Already answered on this side: the upgrade must not clobber it.
    current.set("https://new.example", forKey: "remoteBridge.pairedRemoteURL")

    let adopted = LegacyDefaults.adopt(into: current, from: legacy)

    #expect(adopted.sorted() == ["keepAwake.config", "remoteBridge.lastAppliedSettingsRev"])
    #expect(current.data(forKey: "keepAwake.config") == Data([1, 2, 3]))
    #expect(current.integer(forKey: "remoteBridge.lastAppliedSettingsRev") == 7)
    #expect(current.string(forKey: "remoteBridge.pairedRemoteURL") == "https://new.example")
    // The old domain is left intact so a downgrade still finds its settings.
    #expect(legacy.data(forKey: "keepAwake.config") == Data([1, 2, 3]))
}

@Test func legacyDefaultsAdoptionIsANoOpWhenThereIsNothingToAdopt() throws {
    let name = "LegacyMigrationTests.empty.\(UUID().uuidString)"
    let current = try #require(UserDefaults(suiteName: name))
    defer { current.removePersistentDomain(forName: name) }

    #expect(LegacyDefaults.adopt(into: current, from: nil).isEmpty)
}

@Test func appEnvironmentAdoptsTheLegacyConfigAndPairingFiles() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("legacy-home-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let legacyRoot = home.appendingPathComponent(".notch-hud", isDirectory: true)
    let newRoot = home.appendingPathComponent(".vibenotch", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
    try #"{"defaultMode":"manual"}"#.write(
        to: legacyRoot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
    )
    try #"{"url":"https://old.example","secret":"s"}"#.write(
        to: legacyRoot.appendingPathComponent("remote.json"), atomically: true, encoding: .utf8
    )
    // Already paired on the new side: adoption must not overwrite it.
    try #"{"url":"https://new.example","secret":"s"}"#.write(
        to: newRoot.appendingPathComponent("remote.json"), atomically: true, encoding: .utf8
    )

    let environment = AppEnvironment(fileManager: FakeHomeFileManager(home: home))

    #expect(environment.rootURL == newRoot)
    #expect(
        try String(contentsOf: newRoot.appendingPathComponent("config.json"), encoding: .utf8)
            == #"{"defaultMode":"manual"}"#
    )
    #expect(
        try String(contentsOf: newRoot.appendingPathComponent("remote.json"), encoding: .utf8)
            == #"{"url":"https://new.example","secret":"s"}"#
    )
}

private final class FakeHomeFileManager: FileManager, @unchecked Sendable {
    private let home: URL

    init(home: URL) {
        self.home = home
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL { home }
}
