import Foundation

/// `UserDefaults.standard` is keyed by bundle identifier, so renaming
/// `com.actionable.notchhud` to `com.rebelpaulo.vibenotch` moved the app to an
/// empty persistent domain: every saved Gotta go! setting silently reverted to
/// its default on the first launch after upgrading.
///
/// This copies the old domain's values across once. It never overwrites a value
/// the new domain already holds, and it leaves the old domain alone so a
/// downgrade still finds its settings.
///
/// The identifier below is a HISTORICAL LITERAL — renaming it would point the
/// migration at the domain it is writing into.
enum LegacyDefaults {
    static let legacySuiteName = "com.actionable.notchhud"

    static let migratedKeys = [
        "keepAwake.config",
        "keepAwake.state",
        "remoteBridge.lastAppliedSettingsRev",
        "remoteBridge.pairedRemoteURL",
    ]

    /// - Returns: the keys actually copied, for logging and tests.
    @discardableResult
    static func adopt(
        into defaults: UserDefaults = .standard,
        from legacy: UserDefaults? = UserDefaults(suiteName: legacySuiteName)
    ) -> [String] {
        guard let legacy else { return [] }

        var adopted: [String] = []
        for key in migratedKeys {
            guard defaults.object(forKey: key) == nil,
                  let value = legacy.object(forKey: key)
            else { continue }
            defaults.set(value, forKey: key)
            adopted.append(key)
        }

        if !adopted.isEmpty {
            NSLog("Vibenotch adopted %@ from the previous install", adopted.joined(separator: ", "))
        }
        return adopted
    }
}
