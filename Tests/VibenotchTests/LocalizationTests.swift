import Foundation
import Testing
@testable import Vibenotch

@Test func portugueseTableParsesAndTranslates() throws {
    let pt = try portugueseBundle()

    // A malformed .strings file silently returns the key, so assert a real
    // translation — including one with a format specifier.
    #expect(pt.localizedString(forKey: "Turn on Gotta go!", value: "", table: nil) == "Ligar Gotta go!")
    #expect(pt.localizedString(forKey: "Needs you: %@", value: "", table: nil) == "Precisa de ti: %@")
}

@Test func englishFallsBackToTheSourceStringInsteadOfPortuguese() {
    // en.lproj is empty on purpose; it exists so an English device resolves to
    // it instead of to the only other table.
    #expect(Bundle.module.localizations.contains("en"))
    #expect(t("Turn on Gotta go!") == "Turn on Gotta go!")
}

@Test func everyLocalizedStringHasAPortugueseTranslation() throws {
    let pt = try portugueseBundle()
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Vibenotch")

    // Matches the literal-only t("…") calls; interpolated keys would defeat the
    // whole scheme, so there deliberately are none.
    let call = try NSRegularExpression(pattern: #"\bt\(\s*"((?:[^"\\]|\\.)*)""#)
    var untranslated: [String] = []

    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    for case let url as URL in files! where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        for match in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[range])
            if pt.localizedString(forKey: key, value: "", table: nil).isEmpty {
                untranslated.append(key)
            }
        }
    }

    #expect(untranslated.sorted() == [])
}

private func portugueseBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "pt", withExtension: "lproj"))
    return try #require(Bundle(url: url))
}
