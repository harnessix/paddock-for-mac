import AppKit
import PaddockKit
import XCTest
@testable import PaddockLauncher

/// The welcome window in the app: its code never reaches for the base
/// image, Add App leads to the base image step while none is there, the
/// window with no app opens agents first, and the texts are in the
/// catalog in both languages.
@MainActor
final class WelcomeAppChecks: XCTestCase {
    func source(_ path: String) throws -> String {
        try String(contentsOf: LocalizationTests.root.appendingPathComponent(path), encoding: .utf8)
    }

    // The welcome flow never asks for the base image: the view has no
    // text about it and no code path to its build, its doctor or its
    // views. Those live in BaseImageView, in the Apps section.
    func testWelcomeViewNeverAsksForTheBaseImage() throws {
        let code = try source("App/Views/OnboardingView.swift")
        let lower = code.lowercased()
        for word in ["base image", "macvm", "restore image", "golden", "ipsw"] {
            XCTAssertFalse(lower.contains(word), "OnboardingView says \"\(word)\"")
        }
        for name in ["store.build", "BuildProgressSection", "BuildFailureSection", "BaseImageView", "SpaceGauge",
                     "LibraryArgs.setup", "DoctorPhase", "LocalDoctor", "Prerequisites.rows", "resumeBuild", "cancelBuild"] {
            XCTAssertFalse(code.contains(name), "OnboardingView uses \(name)")
        }
        // The three steps are all it shows.
        XCTAssertTrue(code.contains("WelcomeStep.allCases"))
        XCTAssertEqual(WelcomeStep.allCases.count, 3)
    }

    // Add App with no base image: the base image step first, with the
    // app kept for after the build. With a base image: the review sheet.
    func testAddAppLeadsToTheBaseImageStepWhileNoneIsThere() {
        let store = LauncherStore(service: nil)
        let router = UIRouter()
        // Before paddock said anything: the sheet, and paddock's own check.
        router.addApp(path: nil, store: store)
        XCTAssertEqual(router.sheet, .addApp(path: nil))
        router.sheet = nil

        store.goldenLoaded = true
        router.addApp(path: "/Applications/Notebook.app", store: store)
        XCTAssertNil(router.sheet)
        XCTAssertEqual(store.selection, .baseImage)
        XCTAssertEqual(router.pendingApp, "/Applications/Notebook.app")
        XCTAssertTrue(router.addAfterBuild)
        // Add App with no path keeps the app of the drop.
        router.addApp(path: nil, store: store)
        XCTAssertEqual(router.pendingApp, "/Applications/Notebook.app")

        store.golden = .ready(GoldenInfo(version: "15.1", built: nil, sizeBytes: 25_000_000_000, dir: nil, appsUsing: 0))
        router.addApp(path: "/Applications/Notebook.app", store: store)
        XCTAssertEqual(router.sheet, .addApp(path: "/Applications/Notebook.app"))
        XCTAssertFalse(router.addAfterBuild, "nothing waits for the base image any more")
        XCTAssertNil(router.pendingApp)
    }

    func testWindowWithNoAppOpensOnWhatWaits() {
        XCTAssertNil(HomePick.wait.item)
        XCTAssertEqual(HomePick.baseImage.item, .baseImage)
        XCTAssertEqual(HomePick.agents.item, .agents)
    }

    func testWelcomeStartsAtStepOne() {
        XCTAssertEqual(UIRouter().welcomeStep, WelcomeStep.welcome.rawValue)
        XCTAssertFalse(UIRouter().addAfterBuild)
        XCTAssertNil(UIRouter().pendingApp)
    }

    func testSnapshotWelcomeStep() {
        XCTAssertEqual(SnapshotDump.welcomeStep(["PADDOCK_LAUNCHER_SNAPSHOT_WELCOME": "1"]), .welcome)
        XCTAssertEqual(SnapshotDump.welcomeStep(["PADDOCK_LAUNCHER_SNAPSHOT_WELCOME": "3"]), .start)
        XCTAssertNil(SnapshotDump.welcomeStep(["PADDOCK_LAUNCHER_SNAPSHOT_WELCOME": "4"]))
        XCTAssertNil(SnapshotDump.welcomeStep(["PADDOCK_LAUNCHER_SNAPSHOT_WELCOME": "first"]))
        XCTAssertNil(SnapshotDump.welcomeStep([:]))
    }

    // Reset of the settings does not bring the welcome back.
    func testWelcomeDoneIsNotASetting() throws {
        let code = try source("App/AppContainer.swift")
        let reset = try XCTUnwrap(code.range(of: "static func reset()"))
        let body = code[reset.lowerBound...].prefix(600)
        XCTAssertFalse(body.contains("SettingsKey.welcomeDone"))
    }

    // The texts of the welcome and of the base image step resolve through
    // the catalog, and each has its text in every language.
    func testWelcomeTextsInEveryLanguage() throws {
        XCTAssertEqual(WelcomeCopy.title.localized, "Your computer stays yours")
        let url = LocalizationTests.root.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var keys = WelcomeStep.allCases.map(\.title.key) + WelcomeCopy.points.map(\.key)
        keys += [WelcomeCopy.title.key, WelcomeCopy.apps.key, AgentMode.auto.plainTitle.key]
        keys += ["Skip for now", "Continue", "Back", "Check again", "Installed", "Not installed",
                 "Not installed. Run this command in Terminal:", "Not installed. Install it in Terminal.",
                 "After you install an agent, click Look again.", "Look again",
                 WelcomeCopy.shellFallback.key, "%@ free on this disk",
                 "paddock %@ found, launcher protocol %@", "Or drop a folder on this window.",
                 "Choose an agent and a project folder. The agent opens in the paddock window.",
                 "Mac apps need a base image", "About 13 GB to download, about 25 GB on disk",
                 "10 to 30 minutes on a fast connection", "You can pause the download, quit, and continue later.",
                 "No agents running", "1 agent running", "%lld agents running", "A Mac app can get a room too."]
        for key in keys {
            let entry = try XCTUnwrap(strings[key], "no key: \(key)")
            for language in InterfaceLanguages.all {
                let texts = InterfaceLanguages.texts(entry, language)
                XCTAssertFalse(texts.isEmpty || texts.contains(""), "no \(language) text: \(key)")
                // The same values in every language.
                for value in texts {
                    XCTAssertEqual(InterfaceLanguages.places(value), InterfaceLanguages.places(key), "\(language): \(key)")
                }
            }
        }
    }
}
