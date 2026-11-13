import AppKit
import XCTest

/// German and Russian texts are long. The main screens show in both, at
/// the minimum size of their window, against the fake paddock
/// (Fixtures/files: two apps, agent runs, a failed run, a copy with
/// changes). A text must wrap, or truncate with a tooltip: no labeled
/// control or text is cut, pushed out of its window, or on top of another
/// control.
///
/// macOS builds the accessibility tree of SwiftUI only when an assistive
/// client asks for it. A check in the process of the app saw no label;
/// XCUITest reads the tree from outside, as VoiceOver does.
///
/// A window shows twice: as large as the screen lets it, then at its
/// minimum size (its corner dragged up and left). An element is cut when,
/// at the minimum size, it is narrower than large and not taller (it did
/// not wrap), or narrower than its words in the smallest system font.
/// `testTheCheckFindsACutLabel` proves that a cut label is reported.
///
/// Run once per long language: Scripts/check-languages.sh, or
/// `PADDOCK_LAYOUT_LANGUAGES=de,ru` (the default). Each screen goes to the
/// test report as a screenshot, for a look by eye.
final class LanguageLayoutUITests: XCTestCase {
    static var languages: [String] {
        let asked = ProcessInfo.processInfo.environment["PADDOCK_LAYOUT_LANGUAGES"] ?? "de,ru"
        return asked.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    override func setUp() {
        continueAfterFailure = true
    }

    /// The app in `language`, against the files scenario.
    func launch(_ language: String, scenario: String = "files", env: [String: String] = [:]) -> XCUIApplication {
        var environment = ["PADDOCK_LAUNCHER_FILES_ROOT": Fake.launcherRoot.appendingPathComponent("Fixtures/files-tree").path,
                           "PADDOCK_LAUNCHER_WELCOMED": "1"]
        environment.merge(env) { $1 }
        let locale = ["de": "de_DE", "ru": "ru_RU"][language] ?? language
        return Fake(scenario, env: environment,
                    arguments: ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]).launch()
    }

    // MARK: The checks

    func testTheMainWindowFitsInLongLanguages() throws {
        for language in LanguageLayoutUITests.languages {
            let app = launch(language)
            let catalog = Catalog(language: language)
            XCTAssertTrue(app.element("sidebar").waitForExistence(timeout: 15), "\(language): no main window")
            XCTAssertTrue(app.element("agent-row-claude-1a2b3c").waitForExistence(timeout: 15), "\(language): no agent rows")
            let window = try XCTUnwrap(app.window(containing: "sidebar"), "\(language): no main window")
            // The pages of the main window: an app, the agents, an agent
            // room, a failed run with its card, the Files screen, the
            // questions, the base image.
            let pages: [(String, (XCUIApplication) -> Void)] = [
                ("app", { $0.firstElement(prefix: "app-row-")?.click() }),
                ("agents", { $0.element("sidebar-agents").click() }),
                ("agent", { $0.element("agent-row-claude-1a2b3c").click() }),
                ("agent-failed", { $0.element("agent-row-grok-222222").click() }),
                ("files", { app in
                    app.element("agent-row-claude-1a2b3c").click()
                    let open = app.buttons["files-open"]
                    if open.waitForExistence(timeout: 10) { open.click() }
                    _ = app.element("files-title").waitForExistence(timeout: 10)
                }),
                ("questions", { $0.element("sidebar-questions").click() }),
                ("base-image", { $0.element("sidebar-base-image").click() }),
            ]
            for (name, open) in pages {
                open(app)
                settle()
                check(window, name: "\(language) main-\(name)", minimum: CGSize(width: 760, height: 480),
                      shows: ["Agents", "Questions", "Apps", "Base image"], catalog: catalog)
            }
            app.terminate()
        }
    }

    func testTheNewAgentSheetFitsInLongLanguages() throws {
        for language in ["en"] + LanguageLayoutUITests.languages {
            let app = launch(language)
            XCTAssertTrue(app.element("agent-row-claude-1a2b3c").waitForExistence(timeout: 15), "\(language): no agent rows")
            let window = try XCTUnwrap(app.window(containing: "sidebar"))
            let new = app.buttons["toolbar-new-agent"]
            XCTAssertTrue(new.waitForExistence(timeout: 10), "\(language): no New Agent")
            new.click()
            let sheet = app.element("new-agent-sheet")
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "\(language): no sheet")
            settle()
            // At the default size of the window, the folder, the mode and
            // Start show without a scroll.
            for id in ["new-agent-choose-folder", "new-agent-start"] {
                let element = app.element(id)
                XCTAssertTrue(element.exists, "\(language): no \(id)")
                XCTAssertTrue(element.isHittable, "\(language): \(id) is below the fold")
                XCTAssertTrue(window.frame.contains(element.frame), "\(language): \(id) lies past the window: \(element.frame)")
            }
            XCTAssertTrue(app.element("new-agent-more-agents").exists, "\(language): the agents that are not installed are under a disclosure")
            let found = read(window)
            attach(window, name: "\(language) new-agent-sheet")
            let problems = LayoutRules.problems(found, content: window.frame)
            XCTAssertEqual(problems, [], "\(language) new-agent-sheet:\n" + problems.joined(separator: "\n"))
            app.terminate()
        }
    }

    func testTheWelcomeWindowFitsInLongLanguages() throws {
        for language in LanguageLayoutUITests.languages {
            let app = launch(language, env: ["PADDOCK_LAUNCHER_WELCOMED": "0"])
            let catalog = Catalog(language: language)
            let next = app.buttons["onboarding-continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 15), "\(language): no welcome window")
            let window = try XCTUnwrap(app.window(containing: "onboarding-continue"))
            // The welcome window has one size: no large render.
            for step in 1...3 {
                settle()
                check(window, name: "\(language) welcome-\(step)", minimum: nil,
                      shows: ["Welcome", "Check this Mac", "Start your first agent"], catalog: catalog)
                if step < 3 {
                    expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)
                    waitForExpectations(timeout: 15)
                    next.click()
                }
            }
            app.terminate()
        }
    }

    func testSettingsFitInLongLanguages() throws {
        for language in LanguageLayoutUITests.languages {
            let app = launch(language)
            let catalog = Catalog(language: language)
            XCTAssertTrue(app.element("sidebar").waitForExistence(timeout: 15))
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(app.element("settings-root").waitForExistence(timeout: 10), "\(language): no Settings")
            let window = try XCTUnwrap(app.window(containing: "settings-root"))
            for pane in ["general", "storage", "network", "advanced"] {
                let row = app.element("settings-" + pane)
                XCTAssertTrue(row.waitForExistence(timeout: 5), "\(language): no pane \(pane)")
                row.click()
                settle()
                check(window, name: "\(language) settings-\(pane)", minimum: CGSize(width: 640, height: 560),
                      shows: ["General", "Storage", "Network", "Advanced"], catalog: catalog)
            }
            app.terminate()
        }
    }

    /// The check itself: a label that is too long for its place on purpose
    /// (App/LayoutProbe.swift) must come back as cut. If the tree had no
    /// labels, as in the old in-process check, this test fails.
    func testTheCheckFindsACutLabel() throws {
        let app = launch("en", env: ["PADDOCK_LAUNCHER_LAYOUT_PROBE": "1"])
        let words = "This label is much too long for the narrow place it gets on purpose"
        XCTAssertTrue(app.element("layout-probe").waitForExistence(timeout: 15), "no probe window")
        let window = try XCTUnwrap(app.window(containing: "layout-probe"))
        settle()
        let elements = read(window)
        XCTAssertTrue(elements.contains { $0.label == words }, "the tree has the label: \(elements.map(\.label))")
        let problems = LayoutRules.problems(elements, content: window.frame)
        let cut = problems.filter { $0.contains(words) && $0.contains("is cut") }
        XCTAssertEqual(cut.count, 2, "the cut text and the cut button: \(problems)")
        // And the label with room is no problem.
        let roomy = elements.filter { $0.identifier == "layout-probe-roomy" }
        XCTAssertEqual(roomy.count, 1, "\(elements.map(\.identifier))")
        XCTAssertEqual(LayoutRules.problems(roomy, content: window.frame), [])
        app.terminate()
    }

    // MARK: Helpers

    /// Lets the tasks of a screen load and the layout settle.
    func settle(_ seconds: TimeInterval = 1.5) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Checks one screen of `window`: large, then at `minimum` (nil: a
    /// window of one size). Fails with every problem found.
    func check(_ window: XCUIElement, name: String, minimum: CGSize?, shows keys: [String], catalog: Catalog,
               file: StaticString = #filePath, line: UInt = #line) {
        var problems: [String] = []
        var large: [LayoutRules.Element] = []
        if let minimum {
            resize(window, larger: true)
            settle(0.5)
            large = read(window)
            resize(window, larger: false)
            settle(0.5)
            // The window stops at its minimum width: else it did not shrink.
            if abs(window.frame.width - minimum.width) > 4 {
                problems.append("the window is \(Int(window.frame.width)) pt wide, not its minimum \(Int(minimum.width)) pt")
            }
        }
        let small = read(window)
        attach(window, name: name)
        // No label at all: the tree was not read, and every rule would
        // pass on nothing.
        if small.isEmpty { problems.append("the accessibility tree has no label") }
        problems += LayoutRules.problems(small, content: window.frame)
        if !large.isEmpty { problems += LayoutRules.squeezed(small, large: large) }
        problems += catalog.expect(Set(small.map(\.label)), toShow: keys)
        XCTAssertEqual(problems, [], "cut or covered in \(name):\n" + problems.joined(separator: "\n"), file: file, line: line)
    }

    /// Drags the lower right corner of the window: far down and right
    /// (as large as the screen lets it), or up and left (its minimum).
    func resize(_ window: XCUIElement, larger: Bool) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = larger
            ? corner.withOffset(CGVector(dx: 3000, dy: 3000))
            : window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 40, dy: 40))
        corner.press(forDuration: 0.3, thenDragTo: target)
    }

    /// The labeled controls and texts of the window, from its tree.
    func read(_ window: XCUIElement) -> [LayoutRules.Element] {
        guard let snapshot = try? window.snapshot() else { return [] }
        return LayoutRules.elements(of: snapshot)
    }

    func attach(_ window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The texts of Localizable.xcstrings in one language, read from the repo.
struct Catalog {
    let language: String
    let texts: [String: String]

    init(language: String) {
        self.language = language
        let url = Fake.launcherRoot.appendingPathComponent("App/Resources/Localizable.xcstrings")
        var texts: [String: String] = [:]
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = root["strings"] as? [String: Any] {
            for (key, entry) in strings {
                let loc = ((entry as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]
                if let value = (loc?["stringUnit"] as? [String: Any])?["value"] as? String { texts[key] = value }
            }
        }
        self.texts = texts
    }

    /// The screen shows its language: one of its words that differs from
    /// the English one is in it. A screen that stayed English would pass
    /// every layout rule.
    func expect(_ labels: Set<String>, toShow keys: [String]) -> [String] {
        guard language != "en" else { return [] }
        let words = keys.compactMap { key in texts[key].flatMap { $0 == key ? nil : $0 } }
        if words.isEmpty { return ["the catalog has no \(language) text for \(keys)"] }
        if words.contains(where: { word in labels.contains { $0.contains(word) } }) { return [] }
        return ["none of \(words) shows: the screen is not in \(language)"]
    }
}

/// The layout rules on the accessibility elements of a window, as XCUITest
/// reads them.
enum LayoutRules {
    struct Element {
        var type: XCUIElement.ElementType
        var label: String
        var identifier: String
        var frame: CGRect
        /// The tooltip, when the tree gives it: a cut text with one is allowed.
        var help: String
        /// In a scroll view: its frame may lie past the window.
        var scrolled: Bool
        /// The place in the tree, to tell a control from the ones in it.
        var path: [Int]
        var role: String { "\(type.name)" }
    }

    static let controls: Set<XCUIElement.ElementType> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .link, .disclosureTriangle,
    ]
    static let texts: Set<XCUIElement.ElementType> = [.staticText]

    /// The labeled controls and texts under `snapshot`.
    static func elements(of snapshot: XCUIElementSnapshot) -> [Element] {
        var out: [Element] = []
        walk(snapshot, scrolled: false, path: [], depth: 0, into: &out)
        return out
    }

    private static func walk(_ node: XCUIElementSnapshot, scrolled: Bool, path: [Int], depth: Int, into out: inout [Element]) {
        guard depth < 80 else { return }
        let type = node.elementType
        if controls.contains(type) || texts.contains(type) {
            let words = [node.title, node.label, node.value as? String]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            if !words.isEmpty, node.frame.width > 0, node.frame.height > 0 {
                out.append(Element(type: type, label: words, identifier: node.identifier, frame: node.frame,
                                   help: help(node), scrolled: scrolled, path: path))
            }
        }
        let inScroll = scrolled || type == .scrollView
        for (index, child) in node.children.enumerated() {
            walk(child, scrolled: inScroll, path: path + [index], depth: depth + 1, into: &out)
        }
    }

    /// The tooltip of an element, if XCUITest gives it under any name.
    static func help(_ node: XCUIElementSnapshot) -> String {
        for (key, value) in node.dictionaryRepresentation {
            let name = key.rawValue.lowercased()
            if name.contains("help") || name.contains("tooltip"), let text = value as? String { return text }
        }
        return ""
    }

    /// The width of a text on one line in the system font of `size`.
    static func width(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
    }

    /// One line of the smallest text of the app (10 pt), with room.
    static func isOneLine(_ element: Element) -> Bool { element.frame.height < 26 }

    static func isInside(_ a: [Int], _ b: [Int]) -> Bool { a.count > b.count && Array(a.prefix(b.count)) == b }

    /// The rules that one screen shows: pushed out of the window, words
    /// that do not fit even in the smallest font, controls on top of
    /// each other.
    static func problems(_ elements: [Element], content: CGRect) -> [String] {
        var found: [String] = []
        let window = content.insetBy(dx: -1, dy: -1)
        for element in elements where !element.scrolled {
            if !window.contains(element.frame) {
                found.append("\(element.role) \"\(element.label)\" lies past the window: \(element.frame) in \(content)")
            }
        }
        for element in elements where isOneLine(element) && element.help.isEmpty {
            // A control as small as its symbol shows no words: its label
            // is for VoiceOver.
            if controls.contains(element.type), element.frame.width <= 40 { continue }
            let need = width(element.label, size: 10)
            if need > element.frame.width + 2 {
                found.append("\(element.role) \"\(element.label)\" is cut: needs \(Int(need)) pt, has \(Int(element.frame.width)) pt")
            }
        }
        let buttons = elements.filter { controls.contains($0.type) }
        for (i, a) in buttons.enumerated() {
            for b in buttons[(i + 1)...] where !isInside(a.path, b.path) && !isInside(b.path, a.path) {
                let both = a.frame.intersection(b.frame)
                if !both.isNull, both.width > 2, both.height > 2 {
                    found.append("\(a.role) \"\(a.label)\" covers \(b.role) \"\(b.label)\"")
                }
            }
        }
        return found
    }

    /// Elements that are narrower at the minimum size than at the large
    /// one and not taller: their words were cut, not wrapped. An element
    /// that only stretches wide (wider than its words) does not count.
    static func squeezed(_ small: [Element], large: [Element]) -> [String] {
        func keyed(_ elements: [Element]) -> [String: Element] {
            var seen: [String: Int] = [:]
            var out: [String: Element] = [:]
            for element in elements {
                let base = element.role + "|" + element.label
                let index = seen[base, default: 0]
                seen[base] = index + 1
                out[base + "|\(index)"] = element
            }
            return out
        }
        let wide = keyed(large)
        var found: [String] = []
        for (key, element) in keyed(small) {
            guard let roomy = wide[key], isOneLine(element), element.help.isEmpty else { continue }
            if controls.contains(element.type), element.frame.width <= 40 { continue }
            let tallerOrSame = element.frame.height >= roomy.frame.height - 1
            let fitsItsWords = roomy.frame.width <= width(element.label, size: NSFont.systemFontSize) + 48
            if tallerOrSame, element.frame.height <= roomy.frame.height + 1, fitsItsWords,
               element.frame.width < roomy.frame.width - 2 {
                found.append("\(element.role) \"\(element.label)\" is cut: \(Int(element.frame.width)) pt of \(Int(roomy.frame.width)) pt")
            }
        }
        return found.sorted()
    }
}

extension XCUIElement.ElementType {
    var name: String {
        switch self {
        case .button: return "button"
        case .checkBox: return "checkbox"
        case .radioButton: return "radio button"
        case .popUpButton: return "pop-up button"
        case .menuButton: return "menu button"
        case .link: return "link"
        case .disclosureTriangle: return "disclosure"
        case .staticText: return "text"
        default: return "element \(rawValue)"
        }
    }
}

extension XCUIApplication {
    /// The window with an element of this identifier.
    func window(containing id: String) -> XCUIElement? {
        for index in 0..<windows.count {
            let window = windows.element(boundBy: index)
            if window.descendants(matching: .any)[id].exists { return window }
        }
        return nil
    }

    /// The first element whose identifier starts with `prefix`.
    func firstElement(prefix: String) -> XCUIElement? {
        let element = descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        return element.waitForExistence(timeout: 10) ? element : nil
    }
}
