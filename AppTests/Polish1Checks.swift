import PaddockKit
import SwiftUI
import XCTest
@testable import PaddockLauncher

/// The polish checks in the app target: the texts through the bundle, and the
/// rules that the views follow. The test host runs in English.
@MainActor
final class Polish1Checks: XCTestCase {
    func source(_ path: String) throws -> String {
        try String(contentsOf: LocalizationTests.root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Texts

    // The bundle is the catalog of the interface language. In English a
    // line of paddock shows as it is, with nothing under Details.
    func testTheBundleCatalogResolvesTextsAndLinesOfPaddock() {
        XCTAssertTrue(BundleCatalog.shared.isEnglish, "the test host runs in English")
        XCTAssertEqual(BundleCatalog.shared.format("No apps yet"), "No apps yet")
        XCTAssertNil(BundleCatalog.shared.format("a key that the catalog does not have"))
        let line = UIText.cli("the frobnicator is jammed", else: UIText("Stopped with an error"))
        XCTAssertEqual(line.localized, "the frobnicator is jammed")
        XCTAssertNil(line.hiddenDetails)
        let now = Date()
        XCTAssertEqual(UIText("Used %@", Format.age(since: now.addingTimeInterval(-180), now: now)).localized, "Used 3 min ago")
        XCTAssertEqual(NextStartCopy.text("cold: the first start of this profile").localized,
                       "Cold, about 40 s: the first start of this profile")
    }

    // The lines that the launcher writes about the question list are
    // texts of the catalog, not raw strings.
    func testTheQuestionLinesOfTheLauncherAreInTheCatalog() {
        for text in QuestionProblem.ownTexts {
            XCTAssertNotNil(BundleCatalog.shared.format(text.key), text.key)
            XCTAssertEqual(QuestionProblem.issue(text.key).message, text)
            XCTAssertNil(QuestionProblem.issue(text.key).details)
            XCTAssertFalse(QuestionProblem.issue(text.key).message.isCLI)
        }
        XCTAssertEqual(QuestionProblem.ownTexts.count, 4)
        // The store writes exactly these lines.
        let store = try? source("PaddockKit/Sources/PaddockKit/LauncherStore.swift")
        for text in QuestionProblem.ownTexts {
            XCTAssertTrue(store?.contains("\"" + text.key + "\"") == true, text.key)
        }
    }

    // MARK: The app hero

    func testTheHeroShowsTheReasonOnlyForAnErrorOrABlock() {
        let now = Date()
        XCTAssertNil(HeroCopy.reason(StatusPresentation.of(.stopped, now: now)))
        XCTAssertNil(HeroCopy.reason(StatusPresentation.of(.running(since: nil, windows: 2), now: now)))
        XCTAssertNil(HeroCopy.reason(StatusPresentation.of(.error(reason: ""), now: now)))
        XCTAssertEqual(HeroCopy.reason(StatusPresentation.of(.error(reason: "The VM stopped: out of memory"), now: now))?.localized,
                       "The VM stopped: out of memory")
        XCTAssertEqual(HeroCopy.reason(StatusPresentation.of(.blocked(reason: "x", code: nil), now: now))?.localized, "x")
    }

    // The hero has one prominent button, and it comes from HeroAction.
    func testTheHeroHasOneProminentButton() throws {
        let code = try source("App/Views/Library/SessionViews.swift")
        let start = try XCTUnwrap(code.range(of: "struct SessionHeader: View"))
        let end = try XCTUnwrap(code.range(of: "enum HeroCopy"))
        let hero = String(code[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(hero.components(separatedBy: ".borderedProminent").count - 1, 1)
        XCTAssertTrue(hero.contains("HeroAction.of(app.state, golden: store.golden, goldenLoaded: store.goldenLoaded)"))
        XCTAssertTrue(hero.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(hero.contains("store.selection = .baseImage"), "the base image action leads to its page")
    }

    // The Overview has no row that repeats the state, no empty bar, and
    // Remove App behind Advanced.
    func testTheOverviewHasNoStateRowAndNoEmptyMeter() throws {
        let code = try source("App/Views/AppDetailView.swift")
        XCTAssertFalse(code.contains("overview-state"))
        XCTAssertFalse(code.contains("Text(\"State\")"))
        XCTAssertFalse(code.contains("Section(\"Status\")"))
        XCTAssertFalse(code.contains("Picker(\"Network\""), "the row of the Network group is Access")
        XCTAssertTrue(code.contains("StorageSummary.of(app.json)"))
        XCTAssertTrue(code.contains("StorageSummary.nothingYetLine"))
        XCTAssertFalse(code.contains("if parts.isEmpty"), "an empty bar")
        let advanced = try XCTUnwrap(code.range(of: "if advancedOpen {"))
        let remove = try XCTUnwrap(code.range(of: "\"remove-app-button\""))
        XCTAssertLessThan(advanced.lowerBound, remove.lowerBound, "Remove App is behind Advanced")
        XCTAssertTrue(code.contains("@State private var advancedOpen = false"), "Advanced is closed at first")
    }

    func testTheBasePanelOfAnAppShowsOnlyABuildOrAFailure() {
        XCTAssertFalse(BaseImageWait.shows(.none))
        XCTAssertTrue(BaseImageWait.shows(.building(BuildProgress())))
        XCTAssertTrue(BaseImageWait.shows(.failed(BuildFailure(step: nil, code: "stopped", reason: ""))))
        XCTAssertFalse(BaseImageWait.shows(.ready(GoldenInfo(version: "15", built: nil, sizeBytes: 1, dir: nil, appsUsing: 0))))
    }

    // MARK: Chrome

    // Every control of the window chrome has its words: no bare plus,
    // no switch of two bare symbols, and the switch only where it acts.
    func testTheChromeHasLabelsAndShowsOnlyWhereItActs() throws {
        let window = try source("App/Views/MainWindow.swift")
        XCTAssertFalse(window.contains("Image(systemName: \"plus\")"), "a lone plus")
        XCTAssertTrue(window.contains("Label { Text(\"Add App…\").labelInk() }"))
        XCTAssertTrue(window.contains("\"add-app-button\""))
        XCTAssertTrue(window.contains("ToolbarRule.showsLayoutSwitch(store.selection"))
        XCTAssertTrue(window.contains(".labelStyle(.titleAndIcon)"), "New Agent shows its title")
        XCTAssertTrue(window.contains("SidebarBrand()"))
        XCTAssertTrue(window.contains(".navigationTitle(Text(windowTitle))"))
        let grid = try source("App/Views/Rooms/RoomsGrid.swift")
        XCTAssertFalse(grid.contains(".labelStyle(.iconOnly)"), "the List / Rooms switch has its words")
    }

    // MARK: The base image page

    // One progress for the build; the steps are a checklist with no bar
    // of their own and no empty line for a step that did not start.
    func testTheBuildHasOneProgress() throws {
        let code = try source("App/Views/BaseImageView.swift")
        let start = try XCTUnwrap(code.range(of: "struct BuildProgressSection: View"))
        let end = try XCTUnwrap(code.range(of: "struct BuildNoteLine: View"))
        let build = String(code[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(build.components(separatedBy: "ProgressView(").count - 1, 1)
        XCTAssertTrue(build.contains("progress.overallFraction"))
        XCTAssertTrue(build.contains("progress.headline"))
        XCTAssertTrue(build.contains("BuildStep.allCases"))
        XCTAssertTrue(build.contains("BaseImageHero("), "the build has the room art")
        XCTAssertTrue(build.contains("\"close-note\""))
    }

    // MARK: Requests

    func testTheRequestsShowTheirAgeAndTheExpiredOnesClear() throws {
        let card = try source("App/Views/Agents/AgentRequestCard.swift")
        XCTAssertTrue(card.contains("RequestAge.asked(request.created, now: now)"))
        let questions = try source("App/Views/QuestionsView.swift")
        XCTAssertTrue(questions.contains("RequestAge.isExpired($0, now: context.date)"))
        XCTAssertTrue(questions.contains("await agents.answer(request, .deny)"))
        XCTAssertTrue(questions.contains("await store.answer(question, panel: .deny)"))
        XCTAssertTrue(questions.contains("\"clear-expired\""))
    }

    // MARK: Empty states

    // Each empty section has its room art and its main action.
    func testEachEmptySectionHasItsRoom() throws {
        let window = try source("App/Views/MainWindow.swift")
        let agents = try source("App/Views/Agents/AgentViews.swift")
        let questions = try source("App/Views/QuestionsView.swift")
        for (name, code, view) in [("apps", window, "struct EmptyAppsView: View"), ("home", window, "struct SelectAppView: View"),
                                   ("agents", agents, "struct NoAgentsView: View"), ("questions", questions, "struct QuestionsView: View")] {
            let start = try XCTUnwrap(code.range(of: view), name)
            XCTAssertTrue(code[start.lowerBound...].prefix(4200).contains("StagedRoom("), "no room art: \(name)")
        }
        XCTAssertTrue(agents.contains("AgentsEmpty.of(loaded: agents.harnessesLoaded && !agents.gaps.contains(.list)"))
        XCTAssertTrue(agents.contains("agents.agentHarnesses.filter"), "desktop apps of paddock's list are no agents")
        XCTAssertTrue(agents.contains("\"agents-look-again\""))
    }
}
