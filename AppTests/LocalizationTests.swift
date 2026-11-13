import PaddockKit
import XCTest
@testable import PaddockLauncher

/// The string catalog matches the code: no missing key, no unused key, no
/// literal that bypasses the catalog. The same rules as Scripts/strings.py.
final class LocalizationTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AppTests
        .deletingLastPathComponent() // launcher

    static let literal = #""((?:[^"\\]|\\.)*)""#
    static let calls = ["Text", "Button", "Label", "Toggle", "Picker", "Section", "LabeledContent", "TextField",
                        "Menu", "TableColumn", "ContentUnavailableView", "Window", "CommandMenu", "Link"]

    func regex(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: pattern)
    }

    func matches(_ regex: NSRegularExpression, in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        }
    }

    func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    func swiftFiles(_ folder: String) -> [URL] {
        let base = LocalizationTests.root.appendingPathComponent(folder)
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    func testCatalogMatchesTheCode() throws {
        let names = LocalizationTests.calls.map { NSRegularExpression.escapedPattern(for: $0) + #"\("# }
            + [#"String\(localized:"#]
        let callRE = try regex(#"(?<![\w.])(?:"# + names.joined(separator: "|") + #")\s*"# + LocalizationTests.literal)
        let uiTextRE = try regex(#"UIText\(\s*(?:key:\s*)?"# + LocalizationTests.literal)
        let anyRE = try regex(LocalizationTests.literal)
        var keys: [String: String] = [:]
        var problems: [String] = []
        for (folder, inApp) in [("App", true), ("PaddockKit/Sources", false)] {
            for file in swiftFiles(folder) {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (number, line) in text.components(separatedBy: "\n").enumerated() {
                    let marked = line.trimmingCharacters(in: .whitespaces).hasSuffix("// localized")
                    let code = marked ? line : (line.components(separatedBy: "//").first ?? "")
                    var found = matches(uiTextRE, in: code)
                    if inApp {
                        found += matches(callRE, in: code)
                        if marked { found += matches(anyRE, in: line.components(separatedBy: "// localized")[0]) }
                        if code.contains("Text(verbatim: \"") {
                            problems.append("\(file.lastPathComponent):\(number + 1): Text(verbatim:) with a literal")
                        }
                    }
                    for raw in found {
                        if raw.contains("\\(") {
                            problems.append("\(file.lastPathComponent):\(number + 1): interpolation in a localized literal")
                            continue
                        }
                        keys[unescape(raw)] = keys[unescape(raw)] ?? "\(file.lastPathComponent):\(number + 1)"
                    }
                }
            }
        }
        let catalogURL = LocalizationTests.root.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let have = Set((catalog?["strings"] as? [String: Any] ?? [:]).keys)
        for key in Set(keys.keys).subtracting(have).sorted() {
            problems.append("\(keys[key]!): missing in the catalog: \(key)")
        }
        for key in have.subtracting(keys.keys).sorted() {
            problems.append("unused key in the catalog: \(key)")
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        XCTAssertGreaterThan(keys.count, 100)
    }

    /// Every key has an English value; the other languages can be filled
    /// without code changes.
    func testEveryKeyHasEnglish() throws {
        let catalogURL = LocalizationTests.root.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for (key, entry) in strings {
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let unit = en?["stringUnit"] as? [String: Any]
            XCTAssertEqual(unit?["value"] as? String, key)
        }
    }

    /// One language per interface: every key has a text in every language
    /// of `InterfaceLanguages.all`, and each text (each plural form of a
    /// count) takes the same values as its key, in order with `%@` and
    /// `%lld` or by place with `%1$@`. The same rule as Scripts/strings.py.
    func testEveryKeyHasEveryLanguageWithTheSameValues() throws {
        let catalogURL = LocalizationTests.root.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var problems: [String] = []
        for (key, entry) in strings {
            for language in InterfaceLanguages.all {
                let texts = InterfaceLanguages.texts(entry, language)
                if texts.isEmpty || texts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    problems.append("no \(language) text: \(key)")
                }
                for value in texts where InterfaceLanguages.places(value) != InterfaceLanguages.places(key) {
                    problems.append("\(language): other values than the key: \(key) -> \(value)")
                }
                // A count has the plural forms of the language.
                if key.contains("%lld"), let forms = InterfaceLanguages.pluralForms[language] {
                    let have = Set(InterfaceLanguages.forms(entry, language))
                    if !have.isSuperset(of: forms) { problems.append("\(language): not every plural form: \(key)") }
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.sorted().joined(separator: "\n"))
        XCTAssertGreaterThan(strings.count, 700)
    }

    /// macOS lists every language of the interface for the app, and the
    /// built app has the texts of each: a key resolves in each language.
    func testTheAppHasEveryLanguage() throws {
        let listed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String])
        XCTAssertEqual(Set(listed), Set(["en"] + InterfaceLanguages.all))
        for language in InterfaceLanguages.all {
            XCTAssertTrue(Bundle.main.localizations.contains(language), "no \(language).lproj in the app")
            let catalog = BundleCatalog(language: language)
            let text = try XCTUnwrap(catalog.format("No apps yet"), language)
            XCTAssertNotEqual(text, "No apps yet", language)
        }
    }

    /// The bundle gives the plural form of a count in each language.
    func testTheBundleGivesThePluralForms() {
        let ru = BundleCatalog(language: "ru")
        XCTAssertEqual(UIText("%lld files", 21).resolve(ru).text, "21 файл")
        XCTAssertEqual(UIText("%lld files", 22).resolve(ru).text, "22 файла")
        XCTAssertEqual(UIText("%lld files", 25).resolve(ru).text, "25 файлов")
        let de = BundleCatalog(language: "de")
        XCTAssertEqual(UIText("%lld files", 2).resolve(de).text, "2 Dateien")
        // A count with another value, in the order of the language.
        let ja = UIText("Applied %lld changes to %@. ⌘Z takes it back.", 3, "shop").resolve(BundleCatalog(language: "ja")).text
        XCTAssertTrue(ja.contains("3") && ja.contains("shop") && !ja.contains("%"), ja)
        XCTAssertEqual(UIText("Quit and stop %lld agents?", 2).resolve(BundleCatalog.shared).text, "Quit and stop 2 agents?")
    }

    /// The built app finds its texts: a key resolves through the bundle.
    func testBundleResolvesKeys() {
        let value = Bundle.main.localizedString(forKey: "No apps yet", value: "MISSING", table: nil)
        XCTAssertEqual(value, "No apps yet")
    }
}

/// The languages of the interface besides English, the source: the same
/// list as `LANGUAGES` of Scripts/strings.py and `knownRegions` of
/// project.yml.
enum InterfaceLanguages {
    static let all = ["zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR", "ru", "it"]

    /// The plural forms that a count needs, for the languages with more
    /// than one.
    static let pluralForms: [String: Set<String>] = [
        "es": ["one", "other"], "fr": ["one", "other"], "de": ["one", "other"],
        "pt-BR": ["one", "other"], "it": ["one", "other"], "ru": ["one", "few", "many", "other"],
    ]

    private static func localization(_ entry: [String: Any]?, _ language: String) -> [String: Any]? {
        (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
    }

    /// The texts of a catalog entry in a language: its text, or each
    /// plural form of a count.
    static func texts(_ entry: [String: Any]?, _ language: String) -> [String] {
        let unit = localization(entry, language)
        if let value = (unit?["stringUnit"] as? [String: Any])?["value"] as? String { return [value] }
        let forms = (unit?["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return forms.keys.sorted().compactMap { form in
            ((forms[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    /// The plural forms of a catalog entry in a language.
    static func forms(_ entry: [String: Any]?, _ language: String) -> [String] {
        let unit = localization(entry, language)
        return Array(((unit?["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]).keys)
    }

    /// The values that a text takes: `%@` and `%lld` in order, `%N$@` and
    /// `%N$lld` by place. A sorted list of "place kind".
    static func places(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(@|lld)"#)
        var found: [String] = []
        var following = 0
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let kind = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? "@"
            if let range = Range(match.range(at: 1), in: text), let number = Int(text[range]) {
                found.append("\(number) \(kind)")
            } else {
                following += 1
                found.append("\(following) \(kind)")
            }
        }
        return found.sorted()
    }
}
