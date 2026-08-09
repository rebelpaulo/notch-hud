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
    // The table is read directly rather than asked through the bundle.
    // localizedString(forKey:value:table:) returns the KEY when there is no
    // translation and `value` is empty — so the previous check, which looked
    // for an empty result, could never fail. It passed all session while
    // testing nothing.
    let table = try portugueseTable()
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
            if table[key] == nil {
                untranslated.append(key)
            }
        }
    }

    #expect(untranslated.sorted() == [])
}

/// Portuguese vocabulary this app actually uses. A heuristic, deliberately:
/// a false positive costs an identifier rename, a miss ships untranslated UI
/// to every English user.
private let portugueseWords = [
    "trabalhar", "subagente", "concluíd", "desligad", "ligad", "está", "não",
    "ficheiro", "pasta", "sessão", "sessões", "bateria", "tampa", "ecrã",
    "definiç", "aprovaç", "precisa", "enquanto", "agentes", "utilizador",
    "acordado", "dormir", "terminou", "guardar", "alterar", "telemóvel",
]

private func looksPortuguese(_ line: some StringProtocol) -> Bool {
    let accented = CharacterSet(charactersIn: "ãõçáéíóúâêôàÃÕÇÁÉÍÓÚÂÊÔÀ")
    if line.rangeOfCharacter(from: accented) != nil { return true }
    let lowered = line.lowercased()
    return portugueseWords.contains { lowered.contains($0) }
}

@Test func noPortugueseIsHardcodedOutsideTheStringsTable() throws {
    // The completeness scan only sees strings that reach t(), so it was blind
    // to a literal that skipped t() entirely — which is how "1 subagente a
    // trabalhar" shipped inside an English-source file.
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Vibenotch")
    var offenders: [String] = []

    let files = try #require(
        FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
    )
    for case let url as URL in files where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        // Comment-only lines are prose, and prose is allowed to quote the
        // wrong output it is explaining. A hardcoded string never lives on a
        // line that starts with a comment marker, so nothing is lost.
        where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && looksPortuguese(line) {
            offenders.append("\(url.lastPathComponent):\(number + 1) \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    #expect(offenders == [])
}

@Test func theGuardCatchesTheLineThatCausedIt() {
    // Accented characters alone do NOT match this phrase — every letter in it
    // is ASCII, which is exactly why the first version of this guard would
    // have let its own regression through. Pin the detector to the real line.
    #expect(looksPortuguese(#"            ? "1 subagente a trabalhar""#))
    #expect(looksPortuguese(#"        return "\(count) subagentes a trabalhar""#))
    // And does not fire on the English that replaced it.
    #expect(!looksPortuguese(#"            ? t("1 subagent working")"#))
}

/// The pt table as a dictionary, so "is this key present" is answerable
/// without going through an API that substitutes a fallback.
private func portugueseTable() throws -> [String: String] {
    let url = try #require(
        Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "pt.lproj")
    )
    let contents = try Data(contentsOf: url)
    let parsed = try PropertyListSerialization.propertyList(from: contents, format: nil)
    return try #require(parsed as? [String: String])
}

private func portugueseBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "pt", withExtension: "lproj"))
    return try #require(Bundle(url: url))
}
