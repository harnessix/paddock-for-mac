import XCTest

/// The welcome window: binary discovery, the version gate, the agents and
/// the first agent. Then the base image step of the Apps section: its
/// checklist and the build.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Goes from step 1 to step 2 of the welcome window.
    private func toCheckStep(_ app: XCUIApplication) {
        let next = app.buttons["onboarding-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.click()
    }

    /// Goes from step 2 to step 3, once paddock passed its check.
    private func toStartStep(_ app: XCUIApplication) {
        let next = app.buttons["onboarding-continue"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: next)
        waitForExpectations(timeout: 10)
        next.click()
        XCTAssertTrue(app.buttons["onboarding-start"].waitForExistence(timeout: 10))
    }

    /// The welcome window, by its title.
    private func welcomeWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", "Welcome to paddock")).firstMatch
    }

    /// Fails when the welcome window names the base image, its build or
    /// the virtual machines of the Mac apps.
    private func assertNoBaseImage(_ app: XCUIApplication, _ step: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let window = welcomeWindow(app)
        XCTAssertTrue(window.waitForExistence(timeout: 10), "\(step): no welcome window", file: file, line: line)
        for word in ["base image", "macvm", "virtual machine", "25 GB", "restore image"] {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR title CONTAINS[c] %@",
                                        word, word, word)
            let found = window.descendants(matching: .any).matching(predicate).firstMatch
            XCTAssertFalse(found.exists, "\(step): the welcome says \"\(word)\"", file: file, line: line)
        }
        XCTAssertFalse(window.buttons["onboarding-build"].exists, "\(step): a Build button", file: file, line: line)
        XCTAssertFalse(window.buttons["build-button"].exists, "\(step): a Build button", file: file, line: line)
    }

    /// A project folder in git, for step 3.
    private func makeProject() -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-first-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return folder.path
    }

    /// Starts past the welcome, with no base image, and opens the base
    /// image step as a user does: Add App in the empty window.
    private func toBaseImageStep(_ scenario: String) -> (Fake, XCUIApplication) {
        let fake = Fake(scenario, env: ["PADDOCK_LAUNCHER_WELCOMED": "1"])
        let app = fake.launch()
        openBaseImageStep(app)
        return (fake, app)
    }

    private func openBaseImageStep(_ app: XCUIApplication) {
        let add = app.buttons["empty-add-app"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        XCTAssertTrue(app.element("base-image-guide").waitForExistence(timeout: 10))
    }

    /// A row of the base image step, scrolled into view.
    private func row(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 10,
                     file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.element(id)
        // A grouped Form builds only the rows on screen, and a row of the
        // doctor comes when the doctor answered: look, scroll, wait.
        let end = Date().addingTimeInterval(timeout)
        while !element.exists, Date() < end {
            if app.revealAnywhere(element) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(element.exists, "no \(id)", file: file, line: line)
        return element
    }

    /// The Build button of the base image step, scrolled into view.
    private func buildButton(_ app: XCUIApplication) -> XCUIElement {
        let build = app.buttons["build-button"]
        app.revealAnywhere(build)
        XCTAssertTrue(build.exists, "no Build button")
        return build
    }

    // MARK: The welcome window

    // The whole way: three steps, then the first agent in its pane. No
    // step names the base image, and paddock gets no setup call.
    func testWelcomeNeverAsksForTheBaseImage() {
        let project = makeProject()
        let fake = Fake("fresh", env: ["PADDOCK_LAUNCHER_PICK_FOLDER": project])
        let app = fake.launch()
        XCTAssertTrue(app.buttons["onboarding-continue"].waitForExistence(timeout: 10))
        waitForText(app, "Your computer stays yours")
        // The story is approval and the room, not auto-approval.
        waitForText(app, "It asks you before each step")
        waitForText(app, "It cannot reach your keys or your other projects.")
        for id in ["onboarding-step-1", "onboarding-step-2", "onboarding-step-3"] {
            XCTAssertTrue(app.element(id).exists, id)
        }
        XCTAssertFalse(app.element("onboarding-step-4").exists, "three steps")
        assertNoBaseImage(app, "step 1")

        // Step 2: paddock, the agents with how to install a missing one,
        // and the free space. No check of the virtual machines.
        toCheckStep(app)
        XCTAssertTrue(app.element("prereq-paddock").waitForExistence(timeout: 10))
        waitForText(app, "paddock 0.4.2 found, launcher protocol v1")
        XCTAssertTrue(app.element("welcome-agent-claude").waitForExistence(timeout: 10))
        XCTAssertTrue(app.element("welcome-agent-codex").exists)
        XCTAssertFalse(app.element("welcome-agent-claude-desktop").exists, "a desktop app is not an agent")
        let copilot = app.element("welcome-agent-copilot")
        XCTAssertTrue(copilot.exists)
        XCTAssertEqual(copilot.textFields["command-field"].value as? String, "npm install -g @github/copilot")
        XCTAssertTrue(app.element("prereq-space").exists)
        for id in ["chip", "macos", "memory", "entitlement", "slots", "doctor"] {
            XCTAssertFalse(app.element("prereq-" + id).exists, id)
        }
        assertNoBaseImage(app, "step 2")

        // Step 3: the New Agent form, inline.
        toStartStep(app)
        XCTAssertTrue(app.element("new-agent-choice-claude").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["onboarding-skip"].exists)
        XCTAssertFalse(app.buttons["onboarding-start"].isEnabled, "no folder yet")
        assertNoBaseImage(app, "step 3")
        // How the agent works: "Ask me before each step" comes first, and
        // full auto is not marked as recommended.
        let manual = app.element("new-agent-mode-manual")
        let auto = app.element("new-agent-mode-auto")
        app.revealAnywhere(manual)
        app.revealAnywhere(auto)
        XCTAssertTrue(manual.exists && auto.exists)
        XCTAssertLessThan(manual.frame.minY, auto.frame.minY, "Manual is the first choice")
        XCTAssertTrue(manual.isSelected, "a new user starts in manual mode")
        XCTAssertFalse(auto.isSelected)
        XCTAssertEqual(auto.label.contains("recommended"), false, auto.label)
        app.revealAnywhere(app.buttons["new-agent-choose-folder"])
        app.buttons["new-agent-choose-folder"].click()
        let start = app.buttons["onboarding-start"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: start)
        waitForExpectations(timeout: 10)
        assertNoBaseImage(app, "step 3 with a folder")
        start.click()

        // Start opens the agent pane in the main window.
        XCTAssertTrue(fake.waitForCall("run --quiet claude --network api --no-yolo", timeout: 15), "\(fake.calls.map(\.line))")
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'agent-pane-' OR identifier BEGINSWITH 'agent-terminal-'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "no terminal pane")
        XCTAssertEqual(app.text("agent-title"), "Claude Code in " + (project as NSString).lastPathComponent)
        XCTAssertFalse(welcomeWindow(app).exists, "the welcome window closed")
        XCTAssertTrue(fake.calls("macvm setup").isEmpty, "\(fake.calls.map(\.line))")
        XCTAssertTrue(fake.calls("doctor").isEmpty, "the welcome runs no doctor")
    }

    // "Skip for now" goes to the main window, agents first, and the
    // welcome does not come back at the next launch.
    func testSkipGoesToTheMainWindowAndStays() {
        let suite = "dev.paddock.mac.uitest.welcome." + UUID().uuidString
        let app = Fake("fresh", env: ["PADDOCK_LAUNCHER_DEFAULTS": suite]).launch()
        toCheckStep(app)
        toStartStep(app)
        app.buttons["onboarding-skip"].click()
        XCTAssertTrue(app.element("empty-state").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["empty-new-agent"].exists)
        XCTAssertFalse(welcomeWindow(app).exists)
        app.terminate()

        let again = Fake("fresh", env: ["PADDOCK_LAUNCHER_DEFAULTS": suite]).launch()
        XCTAssertTrue(again.element("empty-state").waitForExistence(timeout: 10))
        XCTAssertFalse(again.buttons["onboarding-continue"].exists)
    }

    // No agent installed: each row says how to install it. The welcome
    // goes on, and step 3 says why Start is off.
    func testMissingAgentShowsHowToInstallIt() {
        let fake = Fake("fresh-no-agents")
        let app = fake.launch()
        toCheckStep(app)
        let claude = app.element("welcome-agent-claude")
        XCTAssertTrue(claude.waitForExistence(timeout: 10))
        XCTAssertEqual(claude.textFields["command-field"].value as? String, "npm install -g @anthropic-ai/claude-code")
        XCTAssertTrue(claude.buttons["copy-button"].exists)
        XCTAssertEqual(app.element("welcome-agent-codex").textFields["command-field"].value as? String,
                       "npm install -g @openai/codex")
        let before = fake.calls("list --json").count
        app.buttons["agents-check-again"].click()
        let end = Date().addingTimeInterval(5)
        while fake.calls("list --json").count <= before, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertGreaterThan(fake.calls("list --json").count, before, "Check again reads the list again")
        toStartStep(app)
        XCTAssertTrue(app.element("new-agent-missing").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("new-agent-missing"), "No agent is installed yet.")
        XCTAssertFalse(app.buttons["onboarding-start"].isEnabled)
        XCTAssertTrue(app.buttons["onboarding-skip"].exists)
    }

    // No paddock anywhere: the install screen with the exact command and Copy.
    func testMissingPaddockShowsInstallCommand() {
        let fake = Fake("fresh", binary: "/nonexistent/paddock")
        let app = fake.launch()
        toCheckStep(app)
        let row = app.element("prereq-paddock")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["command-field"].value as? String, "brew install harnessix/tap/paddock")
        XCTAssertTrue(app.buttons["copy-button"].exists)
        XCTAssertTrue(app.buttons["check-again"].exists)
        XCTAssertFalse(app.buttons["onboarding-continue"].isEnabled)
    }

    func testOldPaddockShowsUpdatePaddock() {
        let app = Fake("old-version").launch()
        waitForText(app, "This version of paddock for Mac needs paddock 0.2.2 or newer. You have 0.2.1.")
        XCTAssertTrue(app.staticTexts["Update paddock"].exists)
        XCTAssertTrue(noText(app, "Update paddock for Mac"))
        XCTAssertTrue(app.buttons["Copy Command"].exists)
    }

    func testNewerMajorShowsUpdatePaddockForMac() {
        let app = Fake("new-version").launch()
        waitForText(app, "Update paddock for Mac")
        XCTAssertTrue(app.buttons["Copy Command"].exists)
    }

    func testEqualVersionPasses() {
        let fake = Fake("ready")
        let app = fake.launch()
        XCTAssertTrue(app.element("sidebar").waitForExistence(timeout: 10))
        XCTAssertTrue(noText(app, "Update paddock"))
    }

    // MARK: The base image step: its checklist
    //
    // The checks of `paddock doctor` are for the Mac apps. They show in
    // the base image step of the Apps section, and Build waits for them.

    func testIntelMacIsADeadEnd() {
        let (_, app) = toBaseImageStep("intel")
        let chip = row(app, "prereq-chip")
        waitForText(app, "paddock app mode needs a Mac with Apple silicon.")
        XCTAssertTrue(chip.buttons["Quit"].exists)
        XCTAssertFalse(buildButton(app).isEnabled)
    }

    func testOldMacOSOffersSystemSettings() {
        let (_, app) = toBaseImageStep("old-macos")
        _ = row(app, "prereq-macos")
        XCTAssertTrue(app.buttons["Update macOS in System Settings"].waitForExistence(timeout: 10))
        XCTAssertFalse(buildButton(app).isEnabled)
    }

    func testLowDiskOffersManageStorage() {
        let (_, app) = toBaseImageStep("low-disk")
        let space = row(app, "prereq-space")
        XCTAssertTrue(app.buttons["Manage Storage…"].waitForExistence(timeout: 10))
        waitForText(app, "11.2 GiB free, 44 GiB needed. Free up 32.8 GiB")
        XCTAssertTrue(space.buttons["check-again"].exists)
        XCTAssertFalse(buildButton(app).isEnabled)
    }

    func testLowMemoryIsOnlyAWarning() {
        let (_, app) = toBaseImageStep("low-memory")
        _ = row(app, "prereq-memory")
        waitForText(app, "8 GiB: each app gets 4 GiB, the minimum.")
        let build = buildButton(app)
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: build)
        waitForExpectations(timeout: 10)
    }

    // The real report of paddock 0.2.2: one row per check, with paddock's
    // line, and no row that still checks.
    func testEveryCheckOfTheReportShows() {
        let (_, app) = toBaseImageStep("fresh")
        // The step says its size and its time before anything starts.
        waitForText(app, "About 13 GB to download, about 25 GB on disk")
        waitForText(app, "10 to 30 minutes on a fast connection")
        _ = row(app, "prereq-chip")
        waitForText(app, "This Mac has Apple silicon (Apple M2).")
        for id in ["chip", "macos", "paddock", "space", "memory", "entitlement", "slots"] {
            _ = row(app, "prereq-" + id)
            if id == "entitlement" { waitForText(app, "paddock-vm has the Virtualization entitlement.") }
        }
        _ = row(app, "space-gauge")
        let build = buildButton(app)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: build)
        waitForExpectations(timeout: 10)
    }

    // A doctor that does not answer: after 20 s the row says so and offers
    // Check Again. It never stays on "Checking…".
    func testSilentDoctorEndsWithCheckAgain() {
        let (_, app) = toBaseImageStep("doctor-hang")
        let doctor = row(app, "prereq-doctor", timeout: 40)
        waitForText(app, "paddock did not answer in 20 seconds.")
        XCTAssertTrue(doctor.buttons["check-again"].exists)
        XCTAssertFalse(buildButton(app).isEnabled)
    }

    // MARK: The base image step: the build

    // The whole way of a first Mac app: the welcome, "Skip for now", Add
    // App, the base image step, Build.
    func testBuildProgressReplay() {
        let fake = Fake("fresh")
        let app = fake.launch()
        toCheckStep(app)
        toStartStep(app)
        app.buttons["onboarding-skip"].click()
        openBaseImageStep(app)
        XCTAssertTrue(fake.calls("macvm setup").isEmpty, "nothing builds before Build")
        let build = buildButton(app)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: build)
        waitForExpectations(timeout: 10)
        build.click()
        XCTAssertTrue(fake.waitForCall("macvm setup --json"))
        // Download: percent, then the estimate once 30 s of stream time passed.
        waitForText(app, "min left")
        XCTAssertTrue(app.element("close-note").exists)
        XCTAssertEqual(app.text("close-note"),
                       "You can close this window; the build continues. Quitting paddock for Mac pauses it.")
        // Pause and resume from the stream.
        waitForText(app, "Paused · 1.2 of 13.1 GB")
        XCTAssertTrue(app.buttons["resume-button"].exists)
        // Install is indeterminate with its typical time; download shows Done.
        waitForText(app, "Installing macOS, about 8 min", timeout: 15)
        XCTAssertTrue(app.element("step-download").images["Done"].exists)
        waitForText(app, "Waiting for the setup window…", timeout: 15)
        waitForText(app, "Follow the steps in paddock's setup window.")
        // Seal, then done: the step offers Add App again.
        XCTAssertTrue(app.element("base-image-done").waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["base-image-add-app"].exists)
    }

    func testBuildFailuresMapToTheirButton() {
        let cases = [("failed-no-space", "Manage Storage…"),
                     ("failed-download", "Try Again"),
                     ("failed-image", "Choose another restore image…")]
        for (scenario, button) in cases {
            let app = Fake(scenario).launch()
            let primary = app.buttons["failure-primary"]
            XCTAssertTrue(primary.waitForExistence(timeout: 10), scenario)
            XCTAssertEqual(primary.label, button, scenario)
            XCTAssertTrue(app.element("failure-reason").exists)
            app.terminate()
        }
    }

    // Quitting during a build pauses it; the next launch shows Paused.
    func testQuitDuringBuildPausesAndRelaunchShowsPaused() {
        let (fake, app) = toBaseImageStep("fresh")
        let build = buildButton(app)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: build)
        waitForExpectations(timeout: 10)
        build.click()
        waitForText(app, "of 13.1 GB")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(fake.waitForCall("macvm setup --pause-download"))
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))

        let paused = Fake("paused").launch()
        waitForText(paused, "Paused · 6.2 of 13.1 GB")
        XCTAssertTrue(paused.buttons["resume-button"].exists)
    }
}
