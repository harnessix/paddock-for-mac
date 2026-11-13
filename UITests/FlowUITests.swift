import XCTest

/// FLOW1: paddock for Mac flows like a finished Mac app.
///
/// - The first Mac app on a Mac with no base image: Add App goes on to
///   the base image step, the app waits there with its room, and after
///   the build the add goes on by itself to the detail of the new app.
/// - A failed build and a failed command show in place, as a plain
///   sentence with the action that fixes it. The line of paddock's CLI
///   is under Details.
/// - A notice of the event stream shows in the window, from the app.
/// - A click on the notification of a waiting request opens its card.
/// - Nothing runs `osascript`.
final class FlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    let notebook = "/Applications/Notebook.app"

    /// The Build button of the base image step, scrolled into view and
    /// enabled: the checks of this Mac passed.
    private func build(_ app: XCUIApplication) -> XCUIElement {
        let build = app.buttons["build-button"]
        app.revealAnywhere(build)
        XCTAssertTrue(build.exists, "no Build button")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: build)
        waitForExpectations(timeout: 15)
        return build
    }

    /// An element of the page, scrolled into view: a grouped Form builds
    /// only the rows on screen.
    @discardableResult
    private func shown(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15,
                       file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.element(id)
        let end = Date().addingTimeInterval(timeout)
        while !element.exists, Date() < end {
            if app.revealAnywhere(element) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(element.exists, "no \(id)", file: file, line: line)
        return element
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    // MARK: The first app without a base image

    // A drop of the first app on a Mac with no base image: the base image
    // step with the app's room, Build, the build with Pause, and then, by
    // itself, the detail of the new app. No blank page on the way.
    func testFirstAppWithoutABaseImage() {
        let fake = Fake("first-app", env: ["PADDOCK_LAUNCHER_WELCOMED": "1", "PADDOCK_LAUNCHER_DROP": notebook])
        let app = fake.launch()
        // Add App checked the base image first: no sheet, the step.
        XCTAssertTrue(app.element("base-image-guide").waitForExistence(timeout: 15))
        XCTAssertEqual(app.sheets.count, 0, "the step is in the window, with no sheet in front of it")
        // The app waits, with its room: in the sidebar and on the page.
        XCTAssertEqual(shown(app, "pending-app-title").text, "Notebook")
        XCTAssertEqual(app.text("pending-app-next"),
                       "Notebook needs the base image. Build it once; Notebook is added when it is ready.")
        XCTAssertTrue(app.element("pending-app-row").exists)
        XCTAssertEqual(app.element("pending-app-row").label, "Notebook, Needs the base image")
        // The size, the time and the free space of the step.
        waitForText(app, "About 13 GB to download, about 25 GB on disk")
        waitForText(app, "10 to 30 minutes on a fast connection")
        shown(app, "space-gauge")
        XCTAssertTrue(fake.calls("app add").isEmpty, "paddock is not asked to add before the base image is there")
        XCTAssertTrue(fake.calls("macvm setup").isEmpty, "nothing builds before Build")

        build(app).click()
        XCTAssertTrue(fake.waitForCall("macvm setup --json --yes"))
        // The build: the steps, Pause, and the room of the app above them.
        XCTAssertTrue(app.buttons["pause-button"].waitForExistence(timeout: 10))
        waitForText(app, "of 14.0 GB")
        XCTAssertEqual(shown(app, "pending-app-title").text, "Notebook")
        XCTAssertEqual(app.text("pending-app-next"),
                       "Notebook is added when the base image is ready. You do not need to wait here.")
        XCTAssertEqual(app.element("pending-app-row").label, "Notebook, Waits for the base image")

        // The build ends: the add goes on by itself, and the window
        // selects the new app and shows its detail.
        let title = app.element("detail-title")
        XCTAssertTrue(title.waitForExistence(timeout: 40), "\(fake.calls.map(\.line))")
        XCTAssertEqual(title.text, "Notebook")
        XCTAssertTrue(app.element("app-row-notebook").exists)
        XCTAssertFalse(app.element("pending-app-row").exists)
        XCTAssertEqual(fake.calls("app add /Applications/Notebook.app --dry-run --json").count, 1)
        XCTAssertEqual(fake.calls("app add /Applications/Notebook.app --name"),
                       ["app add /Applications/Notebook.app --name notebook --memory 6G --json"])
        XCTAssertEqual(fake.calls("app install"), ["app install notebook"])
        // The window says it too.
        XCTAssertTrue(app.element("notice-bar").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("notice-title"), "Notebook is ready")
        // The Base image page offers no second Add App for this app.
        app.element("sidebar-base-image").click()
        XCTAssertTrue(app.element("golden-ready-line").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("base-image-done").exists)
        XCTAssertFalse(app.element("pending-app-title").exists)
    }

    // The same way in the Rooms layout: the detail of the new app opens,
    // not only its card in the grid.
    func testFirstAppOpensItsDetailInTheRoomsLayout() {
        let fake = Fake("first-app", env: ["PADDOCK_LAUNCHER_WELCOMED": "1", "PADDOCK_LAUNCHER_DROP": notebook])
        let app = fake.launch()
        XCTAssertTrue(app.element("base-image-guide").waitForExistence(timeout: 15))
        app.chooseLayout("Rooms")
        build(app).click()
        let title = app.element("detail-title")
        XCTAssertTrue(title.waitForExistence(timeout: 40), "\(fake.calls.map(\.line))")
        XCTAssertEqual(title.text, "Notebook")
    }

    // MARK: A failed build

    // The build fails on the download: the error shows on the page of the
    // build, in a plain sentence, with Try Again. The app keeps waiting.
    // Try Again finishes the build, and the app is added.
    func testFailedBuildShowsItsErrorInPlaceWithTryAgain() {
        let fake = Fake("first-app-fails", env: ["PADDOCK_LAUNCHER_WELCOMED": "1", "PADDOCK_LAUNCHER_DROP": notebook])
        let app = fake.launch()
        XCTAssertTrue(app.element("base-image-guide").waitForExistence(timeout: 15))
        build(app).click()
        let reason = shown(app, "failure-reason", timeout: 20)
        XCTAssertEqual(reason.text, "The download of the restore image stopped: the connection closed.")
        waitForText(app, "Base image not built")
        waitForText(app, "Check your connection, then Try Again.")
        // In the same place: the Base image page, with the app still there.
        XCTAssertTrue(app.element("base-image").exists)
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(app.dialogs.count, 0, "an inline error, no alert")
        XCTAssertEqual(shown(app, "pending-app-title").text, "Notebook")
        XCTAssertEqual(app.element("pending-app-row").label, "Notebook, Waits for the base image · the build stopped")
        XCTAssertTrue(fake.calls("app add").isEmpty)
        // The window tells it as a notice of the app, too.
        XCTAssertTrue(app.element("notice-bar").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("notice-title"), "Base image not built")

        let again = shown(app, "failure-primary")
        XCTAssertEqual(again.label, "Try Again")
        again.click()
        XCTAssertTrue(fake.waitForCall("macvm setup --json --yes --resume"), "\(fake.calls.map(\.line))")
        let title = app.element("detail-title")
        XCTAssertTrue(title.waitForExistence(timeout: 40), "\(fake.calls.map(\.line))")
        XCTAssertEqual(title.text, "Notebook")
        XCTAssertEqual(fake.calls("app add /Applications/Notebook.app --name").count, 1)
    }

    // MARK: The add sheet

    // Add App from the sheet while a build stopped: paddock refuses the
    // app for the base image. The sheet does not stop at that line: the
    // app waits and the window goes on to the base image step. After the
    // build, the add fails once with a line of the CLI: it shows as a
    // plain sentence, the line is under Details, and Try Again adds it.
    func testAddSheetGoesOnToTheBaseImageStep() {
        let fake = Fake("sheet-no-golden", env: ["PADDOCK_LAUNCHER_WELCOMED": "1", "PADDOCK_LAUNCHER_PICK_APP": notebook])
        let app = fake.launch()
        // The window opens on the build that stopped.
        XCTAssertTrue(app.buttons["failure-primary"].waitForExistence(timeout: 15))
        app.buttons["add-app-button"].click()
        XCTAssertTrue(fake.waitForCall("app add /Applications/Notebook.app --dry-run --json"))
        // The sheet went on by itself: no refusal row to read, no button to find.
        XCTAssertEqual(shown(app, "pending-app-title").text, "Notebook")
        waitGone(app.buttons["add-confirm"])
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertFalse(app.buttons["add-build"].exists)
        XCTAssertTrue(noText(app, "Run paddock macvm setup first"), "paddock's refusal line is not the message")
        XCTAssertTrue(app.element("base-image").exists)

        shown(app, "failure-primary").click()
        XCTAssertTrue(fake.waitForCall("macvm setup --json --yes --resume"), "\(fake.calls.map(\.line))")
        // The add fails: the error stays with the app, in plain words.
        let problem = shown(app, "pending-app-problem", timeout: 40)
        XCTAssertEqual(problem.text, "paddock could not do this. Try again. The details say what paddock reported.")
        waitForText(app, "Notebook was not added")
        XCTAssertTrue(noText(app, "os error 35"), "the line of the CLI is not on screen")
        XCTAssertEqual(app.sheets.count, 0)
        XCTAssertEqual(app.dialogs.count, 0)
        XCTAssertFalse(app.element("detail-title").exists)
        // Details shows paddock's own line.
        shown(app, "problem-details-toggle").click()
        let details = shown(app, "problem-details")
        XCTAssertEqual(details.text, "paddock: error: the profile store is locked by pid 811 (os error 35)")

        shown(app, "pending-app-retry").click()
        let title = app.element("detail-title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "\(fake.calls.map(\.line))")
        XCTAssertEqual(title.text, "Notebook")
        XCTAssertEqual(fake.calls("app add /Applications/Notebook.app --name").count, 2)
    }

    // MARK: Notices

    // An event of the stream becomes a notice of the app: it shows in the
    // window, and Show goes to the place it is about.
    func testNoticeFromTheEventStreamShowsInTheApp() {
        let fake = Fake("notices")
        let app = fake.launch()
        XCTAssertTrue(app.element("app-row-Sample Mail").waitForExistence(timeout: 15))
        XCTAssertFalse(app.element("notice-bar").exists)
        // An app session ends in an error.
        fake.inject(#"{"v":1,"kind":"session","app":"Sample Mail","state":"error","reason":"The VM stopped: out of memory"}"#)
        XCTAssertTrue(app.element("notice-bar").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("notice-title"), "Sample Mail stopped unexpectedly")
        XCTAssertEqual(app.text("notice-body"), "The VM stopped: out of memory")
        XCTAssertEqual(app.dialogs.count, 0, "a line in the window, no alert")
        // Show: the room of that app, with its state.
        app.element("notice-show").click()
        XCTAssertTrue(app.element("detail-title").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("detail-title"), "Sample Mail")
        waitGone(app.element("notice-bar"))

        // A notice line of paddock, in paddock's words, and Dismiss.
        fake.inject(#"{"v":1,"kind":"notice","id":"n-1","title":"Sample Notes","text":"Sample Notes was updated on this Mac.","app":"Sample Notes"}"#)
        XCTAssertTrue(app.element("notice-bar").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("notice-title"), "Sample Notes")
        XCTAssertEqual(app.text("notice-body"), "Sample Notes was updated on this Mac.")
        app.element("notice-dismiss").click()
        waitGone(app.element("notice-bar"))
        // The same notice again is not shown twice.
        fake.inject(#"{"v":1,"kind":"notice","id":"n-1","title":"Sample Notes","text":"Sample Notes was updated on this Mac.","app":"Sample Notes"}"#)
        // The base image, removed and built somewhere else.
        fake.inject(#"{"v":1,"kind":"golden","state":"ready"}"#)
        XCTAssertTrue(app.element("notice-bar").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("notice-title"), "Base image ready")
        app.element("notice-show").click()
        XCTAssertTrue(app.element("golden-ready-line").waitForExistence(timeout: 10))
    }

    // A click on the notification of a waiting request opens the
    // Questions list on the card of that request.
    func testNotificationOfAWaitingRequestOpensItsCard() {
        let request = "r-1793959140-cc33dd44"
        let fake = Fake("notices", env: ["PADDOCK_LAUNCHER_OPEN_NOTICE": "questions;" + request])
        let app = fake.launch()
        XCTAssertTrue(app.element("agent-request-" + request).waitForExistence(timeout: 15))
        XCTAssertTrue(app.element("card-focus-" + request).waitForExistence(timeout: 10), "the card of the click is marked")
        XCTAssertFalse(app.element("card-focus-r-1793959080-aa11bb22").exists, "the other request is not")
        XCTAssertTrue(app.buttons["agent-answer-once-" + request].exists)
        // The answer takes the card and its mark away.
        app.buttons["agent-answer-once-" + request].click()
        XCTAssertTrue(fake.waitForCall("approvals answer " + request))
        waitGone(app.element("agent-request-" + request))
        XCTAssertFalse(app.element("card-focus-" + request).exists)
    }

    // MARK: The next screen

    // Remove fails with a line of the CLI: the error shows in the sheet,
    // in plain words, and the sheet stays. The second try works, and the
    // window shows the next app, never an empty detail.
    func testFailedRemoveStaysInItsSheetThenSelectsTheNextApp() {
        let fake = Fake("notices")
        let app = fake.launch()
        app.selectApp("Sample Mail")
        app.removeAppButton().click()
        let remove = app.buttons["remove-confirm"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(app.element("remove-failed").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("remove-failed"), "Sample Mail was not removed")
        XCTAssertEqual(app.text("remove-problem"), "paddock could not do this. Try again. The details say what paddock reported.")
        XCTAssertTrue(noText(app, "os error 35"))
        XCTAssertEqual(app.dialogs.count, 0)
        XCTAssertTrue(app.element("app-row-Sample Mail").exists, "the app is still there")
        app.element("problem-details-toggle").click()
        XCTAssertTrue(app.element("problem-details").waitForExistence(timeout: 5))
        XCTAssertTrue(app.text("problem-details").contains("os error 35"), app.text("problem-details"))
        // The sheet is still open: the same button, once more.
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: remove)
        waitForExpectations(timeout: 5)
        remove.click()
        waitForText(app, "Sample Mail removed. 6.6 GB freed.")
        waitGone(app.element("app-row-Sample Mail"))
        // The next item: the app that stays.
        XCTAssertEqual(app.text("detail-title"), "Sample Notes")
        XCTAssertEqual(fake.calls("app remove").count, 2)
    }

    // The last app goes: the empty state of the section, with its action.
    func testRemoveOfTheLastAppShowsTheEmptyState() {
        let fake = Fake("stopped")
        let app = fake.launch()
        for name in ["Sample Mail", "Sample Notes"] {
            app.selectApp(name)
            app.openTab("Overview")
            app.removeAppButton().click()
            let remove = app.buttons["remove-confirm"]
            XCTAssertTrue(remove.waitForExistence(timeout: 5), name)
            remove.click()
            waitGone(app.element("app-row-" + name))
        }
        XCTAssertTrue(app.element("empty-state").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["empty-add-app"].exists)
        XCTAssertFalse(app.element("detail-title").exists)
    }

    // Stop: the room of the app says "Stopped".
    func testStopShowsStopped() {
        let fake = Fake("notices")
        let app = fake.launch()
        app.selectApp("Sample Notes")
        app.buttons["stop-button"].click()
        // Sample Notes has open questions in its list entry: Stop may ask first.
        let confirm = app.buttons["confirm-action"]
        if confirm.waitForExistence(timeout: 2) { confirm.click() }
        XCTAssertTrue(fake.waitForCall("app stop Sample Notes"))
        fake.inject(#"{"v":1,"kind":"session","app":"Sample Notes","state":"stopped"}"#)
        let stopped = NSPredicate(format: "label == 'Stopped'")
        expectation(for: stopped, evaluatedWith: app.element("detail-status"))
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.text("status-text-Sample Notes"), "Stopped")
        XCTAssertTrue(app.buttons["start-button"].exists)
        XCTAssertFalse(app.element("notice-bar").exists, "a stop that you asked for is no news")
    }

    // Start an agent in the Rooms layout: its pane opens, not only its card.
    func testStartedAgentOpensItsPaneInTheRoomsLayout() {
        let project = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-flow-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let fake = Fake("notices", env: ["PADDOCK_LAUNCHER_PICK_FOLDER": project.path])
        let app = fake.launch()
        XCTAssertTrue(app.element("agent-row-claude-1a2b3c").waitForExistence(timeout: 15))
        app.chooseLayout("Rooms")
        app.element("sidebar-agents").click()
        XCTAssertTrue(app.element("agent-rooms-grid").waitForExistence(timeout: 10))
        app.buttons["toolbar-new-agent"].click()
        XCTAssertTrue(app.element("new-agent-choice-codex").waitForExistence(timeout: 10))
        app.element("new-agent-choice-codex").click()
        app.buttons["new-agent-choose-folder"].click()
        let start = app.buttons["new-agent-start"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 10)
        start.click()
        XCTAssertTrue(fake.waitForCall("run --quiet codex", timeout: 15), "\(fake.calls.map(\.line))")
        // The room of the run, with its pane: the grid is behind it.
        XCTAssertTrue(app.element("agent-title").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("agent-title"), "Codex in " + project.lastPathComponent)
        let pane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'agent-pane-' OR identifier BEGINSWITH 'agent-terminal-'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "no terminal pane")
    }

    // MARK: osascript

    /// The folder of the stand-in for osascript.
    static let shimFolder = Fake.launcherRoot.appendingPathComponent("FakePaddock/bin").path

    // No code path runs osascript. The app runs with a stand-in for it
    // first on its PATH; a call would leave a log. The test goes through
    // every way that tells you something: a session error, a notice of
    // paddock, a question, a failed command, the end of an agent run.
    func testNoCodePathRunsOsascript() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: FlowUITests.shimFolder + "/osascript"))
        let project = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-flow-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let fake = Fake("notices", env: ["PATH": FlowUITests.shimFolder + ":/usr/bin:/bin:/usr/sbin:/sbin",
                                         "PADDOCK_LAUNCHER_PICK_FOLDER": project.path])
        let app = fake.launch()
        XCTAssertTrue(app.element("app-row-Sample Mail").waitForExistence(timeout: 15))
        fake.inject(#"{"v":1,"kind":"session","app":"Sample Mail","state":"error","reason":"The VM stopped: out of memory"}"#)
        XCTAssertTrue(app.element("notice-bar").waitForExistence(timeout: 10))
        fake.inject(#"{"v":1,"kind":"notice","id":"n-2","title":"paddock","text":"A new version of paddock is there."}"#)
        fake.inject(#"{"v":1,"kind":"question","state":"open","id":"q9","app":"Sample Notes","host":"api.example.com","port":443,"opened":"2026-11-06T10:00:00Z"}"#)
        fake.inject(#"{"v":1,"kind":"question","state":"paused","id":"r-p1","app":"Sample Notes","open":21}"#)
        fake.inject(#"{"v":1,"kind":"golden","state":"ready"}"#)
        // A failed command.
        app.selectApp("Sample Mail")
        app.removeAppButton().click()
        XCTAssertTrue(app.buttons["remove-confirm"].waitForExistence(timeout: 5))
        app.buttons["remove-confirm"].click()
        XCTAssertTrue(app.element("remove-failed").waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        // An agent run that starts and is stopped.
        app.buttons["toolbar-new-agent"].click()
        XCTAssertTrue(app.element("new-agent-choice-codex").waitForExistence(timeout: 10))
        app.element("new-agent-choice-codex").click()
        app.buttons["new-agent-choose-folder"].click()
        let start = app.buttons["new-agent-start"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 10)
        start.click()
        XCTAssertTrue(fake.waitForCall("run --quiet codex", timeout: 15))
        XCTAssertTrue(app.buttons["agent-stop"].waitForExistence(timeout: 10))
        app.buttons["agent-stop"].click()
        XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5))
        app.buttons["confirm-action"].click()
        expectation(for: NSPredicate(format: "label == 'Stopped'"), evaluatedWith: app.element("agent-state"))
        waitForExpectations(timeout: 15)
        // The notification timer of the launcher ran at least twice.
        RunLoop.current.run(until: Date().addingTimeInterval(11))

        let log = fake.state.appendingPathComponent("osascript.log")
        let calls = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "osascript ran: \(calls)")
        // The stand-in works: the same folder, asked directly, leaves the log.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: FlowUITests.shimFolder + "/osascript")
        probe.arguments = ["-e", "display notification \"probe\""]
        probe.environment = ["PADDOCK_FAKE_STATE": fake.state.path, "PATH": "/usr/bin:/bin"]
        try probe.run()
        probe.waitUntilExit()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "the stand-in does not log")
    }

    // The code itself: no source of the app or of PaddockKit names
    // osascript, AppleScript or the notification classes before
    // UserNotifications, outside a comment.
    func testNoSourceNamesOsascript() throws {
        var files = 0
        for folder in ["App", "PaddockKit/Sources"] {
            let base = Fake.launcherRoot.appendingPathComponent(folder)
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            for url in (walker?.allObjects as? [URL] ?? []) where url.pathExtension == "swift" {
                files += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for row in text.components(separatedBy: "\n") {
                    let code = row.components(separatedBy: "//").first ?? ""
                    for word in ["osascript", "NSAppleScript", "display notification", "NSUserNotification"] {
                        XCTAssertFalse(code.contains(word), "\(url.lastPathComponent): \(row)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(files, 50)
    }
}
