import XCTest
@testable import PaddockKit

/// One language per interface: texts inside texts, the order of the
/// values in a translation, and the lines of paddock's CLI.
final class TextTests: XCTestCase {
    /// A small Chinese catalog, as the app's bundle gives it.
    static let chinese = TableCatalog([
        "Used %@": "%@使用",
        "%@ min ago": "%@ 分钟前",
        "Ready · saved %@": "就绪 · %@保存",
        "Cold, about 40 s: %@": "冷启动，约 40 秒：%@",
        "the first start of this profile": "此应用的首次启动",
        "see Details": "见详情",
        "Stopped with an error": "出错停止",
        "Error: %@": "错误：%@",
        "%@ GiB free, %@ GiB needed.": "可用 %@ GiB，需要 %@ GiB。",
        "macOS %@ · built %@ · %@": "macOS %@ · %@构建 · %@",
        "%@ Nov": "11月%@日",
        "%@ in %@": "%2$@ 中的 %1$@",
        "no project": "无项目",
        "The bundle %@ is not found. Install the app again, or remove it from paddock.": "找不到应用包 %@。请重新安装该应用，或将其从 paddock 中移除。",
    ])

    // MARK: Values that are texts

    func testAnInnerTextIsLocalizedToo() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = UIText("Used %@", Format.age(since: now.addingTimeInterval(-180), now: now))
        XCTAssertEqual(text.english, "Used 3 min ago")
        XCTAssertEqual(text.resolve(EnglishCatalog()).text, "Used 3 min ago")
        XCTAssertEqual(text.resolve(TextTests.chinese).text, "3 分钟前使用")
    }

    func testTheSavedAgeOfAnAppRowIsLocalized() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = StatusPresentation.of(.saved(since: now.addingTimeInterval(-300)), now: now).text
        XCTAssertEqual(row.english, "Ready · saved 5 min ago")
        XCTAssertEqual(row.resolve(TextTests.chinese).text, "就绪 · 5 分钟前保存")
    }

    func testEqualityIsTheEnglishTextAsBefore() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let inner = Format.age(since: now.addingTimeInterval(-180), now: now)
        XCTAssertEqual(UIText("Used %@", inner), UIText("Used %@", "3 min ago"))
        XCTAssertEqual(UIText.cli("boom", else: UIText("see Details")), UIText(key: "%@", args: ["boom"]))
    }

    func testATranslationCanChangeTheOrderOfTheValues() {
        XCTAssertEqual(UIText.fill("%2$@ 中的 %1$@", ["Codex", "shop"]), "shop 中的 Codex")
        XCTAssertEqual(UIText.fill("%@ of %@", ["1", "2"]), "1 of 2")
        XCTAssertEqual(UIText.fill("100 % of %@", ["it"]), "100 % of it")
        XCTAssertEqual(UIText.fill("%@ and %@", ["one"]), "one and ")
        XCTAssertEqual(UIText.fill("%3$@", ["one"]), "")
        let title = UIText("%@ in %@", "Codex", UIText("no project"))
        XCTAssertEqual(title.english, "Codex in no project")
        XCTAssertEqual(title.resolve(TextTests.chinese).text, "无项目 中的 Codex")
    }

    func testTheBuildDateFollowsTheLanguage() {
        let date = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Format.dayMonthText(date, timeZone: utc).english, Format.dayMonth(date, timeZone: utc))
        XCTAssertEqual(Format.dayMonthText(date, timeZone: utc).resolve(TextTests.chinese).text, "11月3日")
        for month in 1...12 {
            let day = ISO8601DateFormatter().date(from: String(format: "2026-%02d-15T12:00:00Z", month))!
            XCTAssertEqual(Format.dayMonthText(day, timeZone: utc).english, Format.dayMonth(day, timeZone: utc))
        }
    }

    // MARK: Lines of paddock

    func testEnglishShowsALineOfPaddockAsItIs() {
        let text = UIText.cli("the frobnicator is jammed", else: UIText("Stopped with an error"))
        let shown = text.resolve(EnglishCatalog())
        XCTAssertEqual(shown.text, "the frobnicator is jammed")
        XCTAssertNil(shown.details)
        XCTAssertEqual(text.english, "the frobnicator is jammed")
    }

    func testAnotherLanguageNeverShowsAnUnknownLineRaw() {
        let text = UIText.cli("the frobnicator is jammed", else: UIText("Stopped with an error"))
        let shown = text.resolve(TextTests.chinese)
        XCTAssertEqual(shown.text, "出错停止")
        XCTAssertEqual(shown.details, "the frobnicator is jammed")
    }

    func testAKnownLineHasItsCatalogText() {
        let text = UIText.cli("the first start of this profile", else: UIText("see Details"))
        let shown = text.resolve(TextTests.chinese)
        XCTAssertEqual(shown.text, "此应用的首次启动")
        XCTAssertNil(shown.details)
    }

    func testAKnownLineKeepsItsValues() {
        let line = "The bundle /Applications/Notebook.app is not found. Install the app again, or remove it from paddock."
        let shown = UIText.cli(line, else: UIText("see Details")).resolve(TextTests.chinese)
        XCTAssertEqual(shown.text, "找不到应用包 /Applications/Notebook.app。请重新安装该应用，或将其从 paddock 中移除。")
        XCTAssertEqual(UIText.cli("171.4 GiB free, 44 GiB needed.", else: UIText("see Details")).resolve(TextTests.chinese).text,
                       "可用 171.4 GiB，需要 44 GiB。")
    }

    func testAKnownLineWithoutATranslationFallsBack() {
        // The catalog of this test has no text for this known line.
        XCTAssertNotNil(CLIWords.known("The VM stopped: out of memory"))
        let shown = UIText.cli("The VM stopped: out of memory", else: UIText("Stopped with an error")).resolve(TextTests.chinese)
        XCTAssertEqual(shown.text, "出错停止")
        XCTAssertEqual(shown.details, "The VM stopped: out of memory")
    }

    func testALineInsideATextGivesItsDetails() {
        let known = NextStartCopy.text("cold: the first start of this profile")
        XCTAssertEqual(known.english, "Cold, about 40 s: the first start of this profile")
        XCTAssertEqual(known.resolve(TextTests.chinese), ResolvedText(text: "冷启动，约 40 秒：此应用的首次启动", details: nil))
        let unknown = NextStartCopy.text("cold: the moon is full")
        XCTAssertEqual(unknown.english, "Cold, about 40 s: the moon is full")
        XCTAssertEqual(unknown.resolve(TextTests.chinese),
                       ResolvedText(text: "冷启动，约 40 秒：见详情", details: "the moon is full"))
    }

    func testTheErrorOfAnAppRowFollowsTheRule() {
        let row = StatusPresentation.of(.error(reason: "kernel says no"), now: Date())
        XCTAssertEqual(row.text.english, "kernel says no")
        XCTAssertEqual(row.accessibilityLabel.english, "Error: kernel says no")
        XCTAssertEqual(row.text.resolve(TextTests.chinese), ResolvedText(text: "出错停止", details: "kernel says no"))
        XCTAssertEqual(row.accessibilityLabel.resolve(TextTests.chinese).text, "错误：见详情")
    }

    func testTheNextStartLineComesFromPaddocksWord() throws {
        var app = try PaddockJSON.decoder.decode(AppJSON.self, from: Data(#"{"name":"a","state":"stopped"}"#.utf8))
        XCTAssertNil(NextStartCopy.line(app))
        app.nextStartRaw = "warm"
        XCTAssertEqual(NextStartCopy.line(app)?.english, "Warm, about 6 s")
        app.nextStartRaw = nil
        app.nextStart = "Warm, about 10 s"
        XCTAssertEqual(NextStartCopy.line(app)?.english, "Warm, about 10 s")
        XCTAssertTrue(NextStartCopy.line(app)?.isCLI == true)
    }

    // MARK: The table of known lines

    func testTheMatcherTakesTheMostExactLine() {
        XCTAssertEqual(CLIWords.known("macOS 15.1.")?.key, "macOS %@.")
        XCTAssertEqual(CLIWords.known("macOS 15.1.")?.args, ["15.1"])
        let old = "macOS 13.6. paddock app mode needs macOS 14 or newer: update macOS in System Settings."
        XCTAssertEqual(CLIWords.known(old)?.key,
                       "macOS %@. paddock app mode needs macOS %@ or newer: update macOS in System Settings.")
        XCTAssertEqual(CLIWords.known(old)?.args, ["13.6", "14"])
        XCTAssertEqual(CLIWords.known("0 of 2 macOS VMs run.")?.args, ["0", "2"])
        XCTAssertEqual(CLIWords.known("home codex/shared/proj-1f8c90eae3")?.args, ["codex/shared/proj-1f8c90eae3"])
        XCTAssertEqual(CLIWords.known("borrowed copies of codex-proj (/Users/demo/borrow/codex-proj)")?.args,
                       ["codex-proj", "/Users/demo/borrow/codex-proj"])
    }

    func testTheMatcherRefusesOtherLines() {
        XCTAssertNil(CLIWords.known(""))
        XCTAssertNil(CLIWords.known("macOS ."), "a value is never empty")
        XCTAssertNil(CLIWords.known("sealed and more"))
        XCTAssertNil(CLIWords.known("home "))
        XCTAssertNil(CLIWords.known("something else"))
        XCTAssertNil(CLIWords.match("%@ GiB free, %@ GiB needed.", "GiB free, 44 GiB needed."))
        // The English of a known line is the line itself.
        for line in ["16 GiB: each app gets up to 8 GiB.", "the project /private/tmp/x is gone", "sealed"] {
            XCTAssertEqual(CLIWords.known(line)?.english, line)
        }
    }

    /// Every check line of the doctor of the real paddock is known, so
    /// the checklist of "This Mac" has no English line in Chinese.
    func testTheDoctorLinesOfTheRealPaddockAreKnown() throws {
        var seen = 0
        for folder in ["real-0.2.2", "base"] {
            let root = Fixtures.root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: root.path) where file.hasPrefix("doctor") && file.hasSuffix(".json") {
                let data = try Data(contentsOf: root.appendingPathComponent(file))
                guard let doctor = try? PaddockJSON.decoder.decode(DoctorJSON.self, from: data) else { continue }
                for check in doctor.checks {
                    seen += 1
                    XCTAssertNotNil(CLIWords.known(check.text), "\(file): \(check.text)")
                }
            }
        }
        XCTAssertGreaterThan(seen, 10)
    }

    func testTheLauncherOwnLinesStayTexts() {
        XCTAssertEqual(PlainError.shown(LibraryCopy.offline.english), LibraryCopy.offline)
        XCTAssertFalse(PlainError.shown(LibraryCopy.offline.english).isCLI)
        let line = PlainError.shown("error: unexpected argument '--frob'")
        XCTAssertEqual(line.english, "error: unexpected argument '--frob'")
        XCTAssertEqual(line.resolve(TableCatalog([PlainError.oldPaddock.key: "旧"])),
                       ResolvedText(text: "旧", details: "error: unexpected argument '--frob'"))
    }

    func testASpokenLineIsATextOfTexts() {
        let line = UIText.list([UIText("no project"), UIText.verbatim("x"), UIText("see Details")])
        XCTAssertEqual(line.english, "no project, x, see Details")
        XCTAssertEqual(line.resolve(TextTests.chinese).text, "无项目, x, 见详情")
    }

    // MARK: The real catalog

    /// The Chinese texts of the app's catalog, as its bundle gives them.
    static func chineseCatalog() throws -> TableCatalog {
        let url = Fixtures.root.deletingLastPathComponent().appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var table: [String: String] = [:]
        for (key, entry) in strings {
            let chinese = (entry["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any]
            table[key] = (chinese?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        return TableCatalog(table)
    }

    /// The words of a text in Latin letters, without the names that stay
    /// as they are in every language.
    static func englishWords(_ text: String) -> [String] {
        let names: Set<String> = ["paddock", "macOS", "Apple", "Claude", "Code", "Codex", "Homebrew", "Intel", "APFS", "Store"]
        var words: [String] = []
        var word = ""
        for character in text + " " {
            if character.isASCII, character.isLetter {
                word.append(character)
            } else {
                if word.count >= 4, !names.contains(word) { words.append(word) }
                word = ""
            }
        }
        return words
    }

    /// A line of the app in Chinese has no English sentence left in it:
    /// the values that are texts are localized too, and a line of paddock
    /// that the launcher does not know gives way to a Chinese sentence.
    /// These are the lines of the audit of the real screen.
    func testAChineseLineHasNoEnglishInIt() throws {
        let chinese = try TextTests.chineseCatalog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var download = BuildProgress()
        download.apply(SetupJSON(step: "download", bytes: 6_200_000_000, total: 13_100_000_000, rate: 12_000_000, time: now))
        download.apply(SetupJSON(step: "download", bytes: 6_200_000_000, total: 13_100_000_000, rate: 12_000_000,
                                 time: now.addingTimeInterval(40)))
        var install = BuildProgress()
        install.apply(SetupJSON(step: "install", time: now))
        let texts: [UIText] = [
            StatusPresentation.of(.stopped, now: now).text,
            StatusPresentation.of(.saved(since: now.addingTimeInterval(-600)), now: now).text,
            StatusPresentation.of(.running(since: nil, windows: 3), now: now).text,
            StatusPresentation.of(.starting(.copyingApp), now: now).text,
            StatusPresentation.of(.error(reason: "the frobnicator is jammed"), now: now).text,
            StatusPresentation.of(.error(reason: "the frobnicator is jammed"), now: now).accessibilityLabel,
            StatusPresentation.of(.blocked(reason: "Build the base image to start this app.", code: "no_golden"), now: now).text,
            NextStartCopy.text("warm"), NextStartCopy.text("cold"),
            NextStartCopy.text("cold: the first start of this profile"),
            NextStartCopy.text("cold: something new"),
            NextStartCopy.text("refused: something new"),
            OverviewCopy.used(now.addingTimeInterval(-7200), now: now),
            RequestAge.asked(now.addingTimeInterval(-3 * 86_400), now: now)!,
            RequestAge.expiredLine(2), RequestAge.clearNote,
            BuildCopy.readyLine(GoldenInfo(version: "15.1", built: now, sizeBytes: 25_000_000_000, dir: nil, appsUsing: 0)),
            BuildStep.download.title, BuildStep.install.title, BuildStep.guided.title, BuildStep.seal.title,
            download.headline, download.downloadLine!, install.headline, install.detail(of: .install)!, install.estimate,
            BuildCopy.closeNote, StorageSummary.nothingYetLine,
            HeroAction.start.title, HeroAction.buildBaseImage.title, HeroAction.buildBaseImage.note!, HeroAction.showBuild.note!,
            DiskPart(kind: .appCopy, bytes: 1, fraction: 1).title, DiskPart(kind: .savedState, bytes: 1, fraction: 1).title,
            NetworkMode.ask.title, AgentNetwork.text("api"), AgentNetwork.text("mesh"),
            NextStep.firstAgent.title, NextStep.answer(2).title, NextStep.summary(agents: 2, apps: 3)!,
            AgentsEmpty.noneInstalled.title, AgentsEmpty.noneInstalled.text,
            UIText.cli("171.4 GiB free, 44 GiB needed.", else: CLIWords.seeDetails),
            UIText.cli("This Mac has Apple silicon (Apple M2).", else: CLIWords.seeDetails),
            UIText.cli("a line that paddock never wrote before", else: CLIWords.seeDetails),
            PlainError.shown("error: unexpected argument '--frob'"),
        ]
        for text in texts {
            let shown = text.resolve(chinese).text
            XCTAssertFalse(shown.isEmpty, text.english)
            XCTAssertEqual(TextTests.englishWords(shown), [], "\(text.english) -> \(shown)")
        }
        // The line that the launcher does not know is not lost: Details has it.
        XCTAssertEqual(UIText.cli("a line that paddock never wrote before", else: CLIWords.seeDetails).resolve(chinese).details,
                       "a line that paddock never wrote before")
        XCTAssertEqual(StatusPresentation.of(.stopped, now: now).text.resolve(chinese).text, "已停止")
        XCTAssertEqual(BuildStep.seal.title.resolve(chinese).text, "封存")
    }

    /// Every line of `CLIWords` has a Chinese text with its values.
    func testEveryKnownLineOfPaddockHasAChineseText() throws {
        let chinese = try TextTests.chineseCatalog()
        for line in CLIWords.lines {
            let format = try XCTUnwrap(chinese.format(line.key), "no Chinese text: \(line.key)")
            XCTAssertEqual(TextTests.englishWords(format.replacingOccurrences(of: "paddock-vm", with: "")), [], line.key)
        }
    }

    /// Every text that PaddockKit builds is in the catalog, in Chinese:
    /// the keys of all `UIText("…")` in the sources.
    func testEveryTextOfTheKitHasAChineseText() throws {
        let chinese = try TextTests.chineseCatalog()
        let sources = Fixtures.root.deletingLastPathComponent().appendingPathComponent("PaddockKit/Sources")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var seen = 0
        for case let file as URL in walker! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for piece in text.components(separatedBy: "UIText(\"").dropFirst() {
                // The literal ends at the first quote that no backslash escapes.
                var key = ""
                var escaped = false
                for character in piece {
                    if escaped { key.append(character == "n" ? "\n" : character); escaped = false; continue }
                    if character == "\\" { escaped = true; continue }
                    if character == "\"" { break }
                    key.append(character)
                }
                seen += 1
                XCTAssertNotNil(chinese.format(key), "\(file.lastPathComponent): no Chinese text: \(key)")
            }
        }
        XCTAssertGreaterThan(seen, 300)
    }
}
