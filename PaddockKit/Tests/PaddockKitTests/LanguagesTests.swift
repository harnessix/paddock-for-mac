import XCTest
@testable import PaddockKit

/// Every language of the interface, with the real catalog: each key has a
/// text, a count takes the plural form of the language, and the values
/// all show. The same languages as Scripts/strings.py.
final class LanguagesTests: XCTestCase {
    static let languages = ["zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de", "pt-BR", "ru", "it"]

    /// The strings of App/Resources/Localizable.xcstrings.
    static func strings() throws -> [String: [String: Any]] {
        let url = Fixtures.root.deletingLastPathComponent().appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
    }

    /// The catalog of one language, as its bundle gives it: the plain
    /// texts, and the plural forms of the counted keys.
    static func catalog(_ language: String) throws -> TableCatalog {
        var table: [String: String] = [:]
        var plurals: [String: [String: String]] = [:]
        for (key, entry) in try strings() {
            let text = (entry["localizations"] as? [String: Any])?[language] as? [String: Any]
            if let value = (text?["stringUnit"] as? [String: Any])?["value"] as? String {
                table[key] = value
            }
            if let forms = (text?["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                var found: [String: String] = [:]
                for (form, unit) in forms {
                    found[form] = ((unit as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                }
                plurals[key] = found
            }
        }
        return TableCatalog(table, plurals: plurals, language: language)
    }

    // MARK: The rules

    func testTheFillTakesCountsLikeValues() {
        XCTAssertEqual(UIText.fill("%lld changes", ["5"]), "5 changes")
        XCTAssertEqual(UIText.fill("Applied %lld changes to %@.", ["5", "shop"]), "Applied 5 changes to shop.")
        XCTAssertEqual(UIText.fill("%2$@ に %1$lld 件", ["5", "shop"]), "shop に 5 件")
        XCTAssertEqual(UIText.fill("100 % of %@", ["it"]), "100 % of it")
        XCTAssertEqual(UIText.fill("%ll", []), "%ll")
    }

    func testTheShapeOfAFormat() {
        XCTAssertEqual(UIText.shape(of: "Applied %lld changes to %@.").places, 2)
        XCTAssertEqual(UIText.shape(of: "Applied %lld changes to %@.").countPlace, 1)
        XCTAssertEqual(UIText.shape(of: "%@ has %lld files open in %@.").countPlace, 2)
        XCTAssertEqual(UIText.shape(of: "%@ has %lld files open in %@.").places, 3)
        XCTAssertNil(UIText.shape(of: "%@ in %@").countPlace)
        XCTAssertEqual(UIText.shape(of: "No apps yet").places, 0)
    }

    func testAnIntIsACount() {
        let text = UIText("Applied %lld changes to %@. ⌘Z takes it back.", 5, "shop")
        XCTAssertEqual(text.count, 5)
        XCTAssertEqual(text.english, "Applied 5 changes to shop. ⌘Z takes it back.")
        XCTAssertEqual(text.args, ["5", "shop"])
        XCTAssertNil(UIText("Used %@", "3 min ago").count)
    }

    func testThePluralRules() {
        let ru = [1: "one", 2: "few", 4: "few", 5: "many", 11: "many", 12: "many", 14: "many",
                  21: "one", 22: "few", 25: "many", 101: "one", 111: "many", 0: "many"]
        for (count, form) in ru { XCTAssertEqual(PluralRule.form(of: count, language: "ru"), form, "ru \(count)") }
        for language in ["de", "es", "it"] {
            XCTAssertEqual(PluralRule.form(of: 1, language: language), "one")
            XCTAssertEqual(PluralRule.form(of: 0, language: language), "other")
            XCTAssertEqual(PluralRule.form(of: 21, language: language), "other")
        }
        XCTAssertEqual(PluralRule.form(of: 0, language: "fr"), "one")
        XCTAssertEqual(PluralRule.form(of: 2, language: "fr"), "other")
        XCTAssertEqual(PluralRule.form(of: 0, language: "pt-BR"), "one")
        for language in ["zh-Hans", "zh-Hant", "ja", "ko"] {
            XCTAssertEqual(PluralRule.form(of: 1, language: language), "other")
        }
    }

    func testATableCatalogPicksTheForm() {
        let ru = TableCatalog([:], plurals: ["%lld files": ["one": "%lld файл", "few": "%lld файла", "many": "%lld файлов"]],
                              language: "ru")
        XCTAssertEqual(UIText("%lld files", 21).resolve(ru).text, "21 файл")
        XCTAssertEqual(UIText("%lld files", 3).resolve(ru).text, "3 файла")
        XCTAssertEqual(UIText("%lld files", 5).resolve(ru).text, "5 файлов")
        // A text inside a text takes its own count.
        let both = UIText("%@, %@", UIText("%lld files", 2), UIText("%lld files", 11))
        XCTAssertEqual(both.resolve(ru).text, "2 файла, 11 файлов")
    }

    func testAKnownLineOfPaddockKeepsItsCount() throws {
        let line = try XCTUnwrap(CLIWords.known("not used for 22 days"))
        XCTAssertEqual(line.key, "not used for %lld days")
        XCTAssertEqual(line.count, 22)
        XCTAssertEqual(line.english, "not used for 22 days")
        // A count that is not a number is not that line.
        XCTAssertNil(CLIWords.known("not used for many days"))
        let ru = try LanguagesTests.catalog("ru")
        XCTAssertEqual(UIText.cli("not used for 22 days", else: CLIWords.seeDetails).resolve(ru).text, "не используется 22 дня")
    }

    // MARK: The real catalog

    /// Every key has a text in every language, and each text takes the
    /// values of its key.
    func testEveryKeyHasEveryLanguage() throws {
        let strings = try LanguagesTests.strings()
        XCTAssertGreaterThan(strings.count, 1000)
        for language in LanguagesTests.languages {
            let catalog = try LanguagesTests.catalog(language)
            var missing: [String] = []
            for key in strings.keys where catalog.format(key)?.isEmpty != false {
                missing.append(key)
            }
            XCTAssertEqual(missing.sorted(), [], "no \(language) text")
        }
    }

    /// A counted key in a language with plural forms has each form, and
    /// each count shows its number and every value, with no `%` left.
    func testEveryCountShowsInEveryLanguage() throws {
        let strings = try LanguagesTests.strings()
        let counted = strings.keys.filter { $0.contains("%lld") }.sorted()
        XCTAssertGreaterThan(counted.count, 40)
        let forms = ["ru": ["one", "few", "many", "other"], "de": ["one", "other"], "fr": ["one", "other"],
                     "es": ["one", "other"], "it": ["one", "other"], "pt-BR": ["one", "other"]]
        for language in LanguagesTests.languages {
            let catalog = try LanguagesTests.catalog(language)
            for key in counted {
                if let need = forms[language] {
                    XCTAssertEqual(Set(catalog.plurals[key]?.keys.map { $0 } ?? []).isSuperset(of: need), true,
                                   "\(language): \(key) needs the forms \(need)")
                }
                let shape = UIText.shape(of: key)
                for count in [1, 2, 5, 21, 22, 111] {
                    let values: [UIText.Value] = (1...shape.places).map { place in
                        place == shape.countPlace ? .count(count) : .string("‹\(place)›")
                    }
                    let shown = UIText(key: key, values: values).resolve(catalog).text
                    XCTAssertTrue(shown.contains(String(count)), "\(language) \(count): \(key) -> \(shown)")
                    for place in 1...shape.places where place != shape.countPlace {
                        XCTAssertTrue(shown.contains("‹\(place)›"), "\(language) \(count): \(key) -> \(shown)")
                    }
                    XCTAssertFalse(shown.contains("%"), "\(language) \(count): \(key) -> \(shown)")
                }
            }
        }
    }

    /// The Russian forms land where they belong: 1 and 21 the singular,
    /// 3 and 22 the few form, 5 and 11 the many form.
    func testRussianCountsTakeTheirForm() throws {
        let ru = try LanguagesTests.catalog("ru")
        XCTAssertEqual(UIText("%lld files", 21).resolve(ru).text, "21 файл")
        XCTAssertEqual(UIText("%lld files", 22).resolve(ru).text, "22 файла")
        XCTAssertEqual(UIText("%lld files", 11).resolve(ru).text, "11 файлов")
        XCTAssertEqual(UIText("%lld changes", 3).resolve(ru).text, "3 изменения")
        XCTAssertEqual(FilesCopy.changes(5).resolve(ru).text, "5 изменений")
        let de = try LanguagesTests.catalog("de")
        XCTAssertEqual(UIText("%lld files", 2).resolve(de).text, "2 Dateien")
    }

    /// Every value that a translation moves keeps its place: the
    /// Japanese text names the folder after the count.
    func testATranslationMayReorderACount() throws {
        let ja = try LanguagesTests.catalog("ja")
        let text = UIText("Applied %lld changes to %@. ⌘Z takes it back.", 4, "shop")
        let shown = text.resolve(ja).text
        XCTAssertTrue(shown.contains("4"), shown)
        XCTAssertTrue(shown.contains("shop"), shown)
        XCTAssertFalse(shown.contains("%"), shown)
    }
}
