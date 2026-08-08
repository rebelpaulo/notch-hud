import Foundation

/// User-facing text. The English sentence is both the source string and the
/// lookup key, so `t("Turn on Gotta go!")` reads as the thing it prints and a
/// missing translation degrades to English instead of to a key name.
///
/// `Resources/en.lproj/Localizable.strings` is deliberately empty: it only has
/// to exist so macOS counts English among the available localizations, or a
/// device set to English would fall through to the single `pt` table.
func t(_ key: String, _ arguments: any CVarArg...) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: .current, arguments: arguments)
}
