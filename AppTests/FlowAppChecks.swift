import AppKit
import PaddockKit
import UserNotifications
import XCTest
@testable import PaddockLauncher

/// FLOW1 in the app: every message comes from paddock for Mac itself, a
/// click on a notification finds its place, the review sheet hands an app
/// to the base image step, and no code runs `osascript`.
@MainActor
final class FlowAppChecks: XCTestCase {
    func sources(_ folders: [String]) throws -> [(name: String, code: String)] {
        var found: [(String, String)] = []
        for folder in folders {
            let base = LocalizationTests.root.appendingPathComponent(folder)
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            for url in (walker?.allObjects as? [URL] ?? []) where url.pathExtension == "swift" {
                // The code only: a comment may name what the code must not do.
                let text = try String(contentsOf: url, encoding: .utf8)
                let code = text.components(separatedBy: "\n").map { $0.components(separatedBy: "//").first ?? "" }
                    .joined(separator: "\n")
                found.append((url.lastPathComponent, code))
            }
        }
        XCTAssertGreaterThan(found.count, 20)
        return found
    }

    // MARK: Messages

    // No code path runs osascript, AppleScript or the old notification
    // classes: a notification of those shows the icon of Script Editor.
    func testNoCodeRunsOsascript() throws {
        for (name, code) in try sources(["App", "PaddockKit/Sources"]) {
            for word in ["osascript", "NSAppleScript", "display notification", "NSUserNotification", "OSAScript",
                         "NSAppleEventDescriptor"] {
                XCTAssertFalse(code.contains(word), "\(name) uses \(word)")
            }
        }
        // The stand-in that the UI test puts on the PATH is there.
        let shim = LocalizationTests.root.appendingPathComponent("FakePaddock/bin/osascript").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shim), shim)
    }

    // One place posts notifications, with UNUserNotificationCenter.
    func testOnlyTheNoticePosterPostsNotifications() throws {
        for (name, code) in try sources(["App"]) where name != "AppDelegate.swift" {
            XCTAssertFalse(code.contains("UNUserNotificationCenter"), "\(name) posts notifications itself")
            XCTAssertFalse(code.contains("UNMutableNotificationContent"), "\(name) posts notifications itself")
        }
        let delegate = try String(contentsOf: LocalizationTests.root.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(delegate.contains("UNUserNotificationCenter.current()"))
        XCTAssertTrue(delegate.contains("AppContainer.store.onNotice = { NoticePoster.post($0) }"),
                      "the notices of the event stream reach the poster")
        // PaddockKit only names what to tell: it posts nothing.
        for (name, code) in try sources(["PaddockKit/Sources"]) {
            XCTAssertFalse(code.contains("UserNotifications"), "\(name) imports UserNotifications")
        }
    }

    // An alert is for what blocks the app, and it carries the app icon.
    func testAlertsCarryTheAppIcon() throws {
        var alerts = 0
        for (name, code) in try sources(["App"]) {
            let made = code.components(separatedBy: "NSAlert()").count - 1
            if name == "Support.swift" {
                XCTAssertEqual(made, 1, "AppAlert.make is the one place that makes an alert")
            } else {
                XCTAssertEqual(made, 0, "\(name) makes an alert without AppAlert.make")
            }
            alerts += code.components(separatedBy: "AppAlert.make(").count - 1
        }
        // The paddock check, the quit question, the move question and its failure.
        XCTAssertEqual(alerts, 4, "a new alert: is the error blocking? Else show it inline.")
        XCTAssertNotNil(AppAlert.make().icon)
        XCTAssertEqual(AppAlert.make().alertStyle, .warning)
    }

    // The notification: the texts of the notice, and the way back to its place.
    func testANotificationCarriesItsRoute() {
        let notice = Notice(id: "agent-request-r-17", kind: .agentWaiting,
                            title: UIText("%@ in %@ is waiting for you", "Claude Code", "shop"),
                            body: UIText("%@ wants to run a command on your Mac", "Claude Code"),
                            target: .questions, card: "r-17")
        let content = NoticePoster.content(notice)
        XCTAssertEqual(content.title, "Claude Code in shop is waiting for you")
        XCTAssertEqual(content.body, "Claude Code wants to run a command on your Mac")
        var info: [String: String] = [:]
        for (key, value) in content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        let back = NoticeRoute.destination(info)
        XCTAssertEqual(back.target, .questions)
        XCTAssertEqual(back.card, "r-17", "the click opens the Questions list on this card")
        XCTAssertNil(info[NoticePoster.windowKey], "the Questions badge shows it: the system shows its banner")

        let failed = Notice(id: "app-failed-x-1", kind: .appFailed, title: UIText("%@ stopped unexpectedly", "Sample Mail"),
                            body: UIText(key: "%@", args: ["The VM stopped: out of memory"]), target: .app("Sample Mail"))
        XCTAssertEqual(NoticePoster.content(failed).userInfo[NoticePoster.windowKey] as? String, "1")
        XCTAssertEqual(NoticePoster.content(failed).userInfo[NoticeRoute.targetKey] as? String, "app:Sample Mail")
    }

    // In front with the window on screen, a notice of the window line is
    // only listed; every other one shows its banner.
    func testPresentationWhileInFront() {
        XCTAssertEqual(NoticePoster.presentation(inWindow: true, windowVisible: true), [.list])
        XCTAssertEqual(NoticePoster.presentation(inWindow: true, windowVisible: false), [.banner, .list, .sound])
        XCTAssertEqual(NoticePoster.presentation(inWindow: false, windowVisible: true), [.banner, .list, .sound])
    }

    // In a test nothing reaches Notification Center; the poster keeps it.
    func testThePosterKeepsWhatItWasGiven() {
        XCTAssertTrue(AppContainer.isUITest)
        let notice = Notice(id: "check-\(UUID().uuidString)", kind: .message, title: UIText("t"), body: UIText("b"), target: nil)
        NoticePoster.post(notice)
        XCTAssertEqual(NoticePoster.posted.last, notice)
    }

    // A notice of paddock names an agent by its run. The room may have
    // the key of its pane. A room or an app that is gone leads to its
    // section, never to an empty detail.
    func testTheClickFindsTheRoom() {
        let store = LauncherStore(service: nil)
        let pane = AgentPane(id: "pane-1-ab12", kind: .view(runID: "claude-1a2b3c"), harness: "claude", folder: "/Users/demo/shop",
                             started: Date(), runID: "claude-1a2b3c")
        let rooms = AgentRooms.of(runs: [], ended: [], board: [:], requests: [], panes: [pane])
        XCTAssertEqual(rooms.map(\.key), ["pane-1-ab12"])
        XCTAssertEqual(NoticeOpener.resolve(.agent("claude-1a2b3c"), store: store, rooms: rooms), .agent("pane-1-ab12"))
        XCTAssertEqual(NoticeOpener.resolve(.agent("pane-1-ab12"), store: store, rooms: rooms), .agent("pane-1-ab12"))
        XCTAssertEqual(NoticeOpener.resolve(.agent("gone"), store: store, rooms: rooms), .agents)
        XCTAssertEqual(NoticeOpener.resolve(.questions, store: store, rooms: rooms), .questions)
        XCTAssertEqual(NoticeOpener.resolve(.baseImage, store: store, rooms: rooms), .baseImage)
        XCTAssertNil(NoticeOpener.resolve(nil, store: store, rooms: rooms))
        // Before the list loaded, the app of the notice is taken as it is.
        XCTAssertEqual(NoticeOpener.resolve(.app("notebook"), store: store, rooms: rooms), .app("notebook"))
        store.applyList([])
        XCTAssertNil(NoticeOpener.resolve(.app("notebook"), store: store, rooms: rooms), "the empty state of the section")
    }

    // MARK: The first app without a base image

    func review(_ fixture: String) throws -> AddReview {
        let url = LocalizationTests.root.appendingPathComponent("Fixtures/base/" + fixture)
        let report = try XCTUnwrap(LibraryDecode.addReport(try Data(contentsOf: url)))
        return AddReview.of(report: report, path: "/Applications/Notebook.app")
    }

    // The sheet hands the app to the base image step when the base image
    // is the one thing that is missing.
    func testTheSheetGoesOnToTheBaseImageStep() throws {
        let noGolden = try review("add-review-no-golden.json")
        let building = GoldenState.building(BuildProgress())
        let stopped = GoldenState.failed(BuildFailure(step: nil, code: "stopped", reason: "x"))
        let ready = GoldenState.ready(GoldenInfo(version: "15.1", built: nil, sizeBytes: 1, dir: nil, appsUsing: 0))
        XCTAssertTrue(AddHandoff.needsBaseImage(noGolden, golden: .none))
        XCTAssertTrue(AddHandoff.needsBaseImage(noGolden, golden: building))
        XCTAssertTrue(AddHandoff.needsBaseImage(noGolden, golden: stopped))
        // The launcher has a base image and paddock says no: the row stays, you decide.
        XCTAssertFalse(AddHandoff.needsBaseImage(noGolden, golden: ready))
        // Another refusal is about the app: it shows in the sheet.
        XCTAssertFalse(AddHandoff.needsBaseImage(try review("add-review-app-store.json"), golden: .none))
        XCTAssertFalse(AddHandoff.needsBaseImage(try review("add-review-low-space.json"), golden: .none))
        XCTAssertFalse(AddHandoff.needsBaseImage(try review("add-review-existing.json"), golden: .none))
        XCTAssertFalse(AddHandoff.needsBaseImage(try review("add-review-ok.json"), golden: .none))
        XCTAssertFalse(AddHandoff.needsBaseImage(.failed(path: "/Applications/Notebook.app", line: "x"), golden: .none))
    }

    // Every way into Add App keeps the app for after the build.
    func testTheAppWaitsForTheBaseImage() {
        let store = LauncherStore(service: nil)
        let router = UIRouter()
        store.goldenLoaded = true
        // A drop, or Add App with an app.
        router.addApp(path: "/Applications/Notebook.app", store: store)
        XCTAssertEqual(store.pendingAdd, PendingAdd(path: "/Applications/Notebook.app"))
        XCTAssertEqual(store.selection, .baseImage)
        XCTAssertNil(router.sheet)
        // Add App with no app yet keeps the app that waits.
        router.addApp(path: nil, store: store)
        XCTAssertEqual(store.pendingAdd?.path, "/Applications/Notebook.app")

        // The review sheet: paddock said that the base image is missing.
        let other = LauncherStore(service: nil)
        let second = UIRouter()
        second.sheet = .addApp(path: nil)
        second.waitForBaseImage(path: "/Applications/Sample Tasks.app", store: other)
        XCTAssertEqual(other.pendingAdd?.path, "/Applications/Sample Tasks.app")
        XCTAssertEqual(other.pendingAdd?.title, "Sample Tasks")
        XCTAssertEqual(other.selection, .baseImage)
        XCTAssertEqual(second.pendingApp, "/Applications/Sample Tasks.app")
        XCTAssertTrue(second.addAfterBuild)
    }

    // MARK: The next screen

    // The window with no selection, and the selection of an app that is
    // gone, both have a view with the main action of the section.
    func testNoActionLeavesAnEmptyDetail() throws {
        let window = try String(contentsOf: LocalizationTests.root.appendingPathComponent("App/Views/MainWindow.swift"), encoding: .utf8)
        let router = try XCTUnwrap(window.range(of: "@ViewBuilder private var selected: some View"))
        let body = String(window[router.lowerBound...].prefix(1600))
        XCTAssertFalse(body.contains("EmptyView()"), "a selection with nothing to show")
        for view in ["EmptyAppsView()", "SelectAppView()", "QuestionsView()", "BaseImageView()", "AgentsDetail()"] {
            XCTAssertTrue(body.contains(view), "no \(view) in the detail")
        }
        // Each empty state names its main action.
        for id in ["empty-add-app", "empty-new-agent", "select-add-app"] {
            XCTAssertTrue(window.contains("\"\(id)\""), id)
        }
        let agent = try String(contentsOf: LocalizationTests.root.appendingPathComponent("App/Views/Agents/AgentDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(agent.contains("\"gone-new-agent\""), "a run that is gone offers New Agent")
        XCTAssertTrue(agent.contains("\"gone-show-agents\""))
    }

    // Start an agent: the store asks for its room, so the Rooms layout
    // opens the pane and not only the card.
    func testAStartedAgentAsksForItsRoom() throws {
        let sheet = try String(contentsOf: LocalizationTests.root.appendingPathComponent("App/Views/Agents/NewAgentSheet.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("store.openRoom = .agent(key)"))
        let rooms = try String(contentsOf: LocalizationTests.root.appendingPathComponent("App/Views/Agents/AgentViews.swift"), encoding: .utf8)
        XCTAssertTrue(rooms.contains(".onChange(of: store.openRoom, initial: true)"))
        let grid = try String(contentsOf: LocalizationTests.root.appendingPathComponent("App/Views/Rooms/RoomsGrid.swift"), encoding: .utf8)
        XCTAssertTrue(grid.contains(".onChange(of: store.openRoom, initial: true)"))
    }

    // The texts of FLOW1 resolve through the catalog, in both languages.
    func testTheNewTextsInBothLanguages() throws {
        XCTAssertEqual(PlainError.generic.localized, "paddock could not do this. Try again. The details say what paddock reported.")
        let url = LocalizationTests.root.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var keys = [PlainError.generic, PlainError.noAnswer, PlainError.noSpace, PlainError.needsBaseImage, PlainError.stillRunning,
                    PlainError.noNetwork, PlainError.notAllowed, PlainError.oldPaddock, PlainError.notConfirmed].map(\.key)
        keys += ["Details", "Dismiss", "Show", "Do Not Add", "Review…", "Show the Build", "Show All Agents",
                 "From your notification", "%@ stopped unexpectedly", "%@ cannot start", "Base image ready",
                 "Your Mac apps can get their rooms now.", "Questions paused", "%@ is ready", "%@ was not added",
                 "Waits for the base image", "Needs the base image", "Adding…", "Not added",
                 "%@ is added when the base image is ready. You do not need to wait here.",
                 "The build stopped before the base image was ready. Try Again continues where it stopped.",
                 "The answer did not reach paddock. Answer again.", "Stopped"]
        for key in keys {
            let entry = try XCTUnwrap(strings[key], "no key: \(key)")
            for language in InterfaceLanguages.all {
                let texts = InterfaceLanguages.texts(entry, language)
                XCTAssertFalse(texts.isEmpty || texts.contains(""), "no \(language) text: \(key)")
                for value in texts {
                    XCTAssertEqual(InterfaceLanguages.places(value), InterfaceLanguages.places(key), "\(language): \(key)")
                }
            }
        }
    }
}
