import XCTest

/// The polish rules: one hero with one prominent action, grouped facts with no
/// empty meter, advanced options behind a disclosure, toolbar items only
/// where they act, a sidebar that says whose window this is, the age of
/// a request, and the build as one progress with a checklist.
final class Polish1UITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // A new app with no base image: the hero says so and leads to the
    // setup. Storage says what will happen. No "State" row, no empty bar,
    // no zero.
    func testANewAppLeadsToTheBaseImageAndShowsNoEmptyMeter() {
        let app = Fake("new-app").launch()
        app.selectApp("Sample Notes")
        let build = app.buttons["hero-build-base-image"]
        XCTAssertTrue(build.waitForExistence(timeout: 10), "the hero has no base image action")
        XCTAssertEqual(build.label, "Build the Base Image…")
        XCTAssertFalse(app.buttons["start-button"].exists, "Start cannot work without the base image")
        XCTAssertEqual(app.element("detail-status").label, "Stopped")
        XCTAssertTrue(app.element("hero-note").exists)
        // The facts: one line in place of the bar, and no row that
        // repeats the state.
        let empty = app.element("storage-empty")
        XCTAssertTrue(app.revealAnywhere(empty), "no storage line")
        XCTAssertEqual(empty.text, "Nothing stored yet. The first start prepares the app.")
        XCTAssertFalse(app.element("disk-bar").exists)
        XCTAssertFalse(app.element("disk-total").exists)
        XCTAssertFalse(app.element("overview-state").exists)
        XCTAssertTrue(noText(app, "0.0 GB"))
        XCTAssertTrue(noText(app, "Rules: 0"))
        XCTAssertTrue(noText(app, "Open questions: 0"))
        // The action starts the setup: the Base image page.
        build.click()
        XCTAssertTrue(app.element("base-image-guide").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["build-button"].exists)
    }

    // With a base image the one prominent action is Start.
    func testTheHeroOfAStoppedAppStarts() {
        let fake = Fake("stopped")
        let app = fake.launch()
        app.selectApp("Sample Notes")
        let start = app.buttons["start-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["hero-build-base-image"].exists)
        XCTAssertFalse(app.element("hero-note").exists)
        start.click()
        XCTAssertTrue(fake.waitForCall("app run Sample Notes"), "\(fake.calls.map(\.line))")
    }

    // Remove App and Clear Saved State are behind "Advanced".
    func testAdvancedIsClosedUntilYouOpenIt() {
        let app = Fake("stopped").launch()
        app.selectApp("Sample Notes")
        let toggle = app.buttons["advanced-toggle"]
        XCTAssertTrue(app.revealAnywhere(toggle), "no Advanced")
        XCTAssertEqual(toggle.value as? String, "Closed")
        XCTAssertFalse(app.buttons["remove-app-button"].exists)
        XCTAssertFalse(app.buttons["clear-state-button"].exists)
        toggle.click()
        XCTAssertTrue(app.revealAnywhere(app.buttons["remove-app-button"]))
        XCTAssertTrue(app.buttons["clear-state-button"].exists, "a stopped app with a saved state can clear it")
        XCTAssertEqual(toggle.value as? String, "Open")
    }

    // The sidebar says whose window this is, and Add App has its words.
    func testTheSidebarHasTheNameAndALabeledAddApp() {
        let app = Fake("ready").launch()
        let brand = app.element("sidebar-brand")
        XCTAssertTrue(brand.waitForExistence(timeout: 10))
        XCTAssertTrue(brand.label.contains("paddock"), brand.label)
        let add = app.buttons["add-app-button"]
        XCTAssertTrue(add.exists)
        XCTAssertEqual(add.label, "Add App…")
        XCTAssertGreaterThan(add.frame.width, 60, "a lone plus is not a label")
    }

    // New Agent acts on every page and has its title. The List / Rooms
    // switch shows only on a page with rooms.
    func testToolbarItemsShowOnlyWhereTheyAct() {
        let app = Fake("library").launch()
        XCTAssertTrue(app.element("app-row-sample-notes").waitForExistence(timeout: 10))
        let new = app.buttons["toolbar-new-agent"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        XCTAssertEqual(new.label, "New Agent")
        XCTAssertTrue(layoutSwitch(app), "no List / Rooms switch on an app page")
        app.element("sidebar-questions").click()
        XCTAssertTrue(app.element("questions-empty").waitForExistence(timeout: 10))
        XCTAssertFalse(layoutSwitch(app), "the switch does nothing on Questions")
        XCTAssertTrue(new.exists, "New Agent acts on every page")
        app.element("sidebar-base-image").click()
        XCTAssertTrue(app.element("base-image").waitForExistence(timeout: 10))
        XCTAssertFalse(layoutSwitch(app), "the switch does nothing on Base image")
        // The View menu still has both layouts.
        app.chooseLayout("Rooms")
        app.selectApp("sample-notes")
        XCTAssertTrue(app.element("room-card-sample-notes").waitForExistence(timeout: 10))
        XCTAssertTrue(layoutSwitch(app))
    }

    private func layoutSwitch(_ app: XCUIApplication) -> Bool {
        let toolbar = app.toolbars.firstMatch
        return toolbar.radioButtons["Rooms"].exists || toolbar.buttons["Rooms"].exists
            || toolbar.segmentedControls.buttons["Rooms"].exists || app.element("library-layout").exists
    }

    // The base image that is there: its room, what it is, and Remove
    // behind "Advanced".
    func testTheReadyBaseImagePage() {
        let app = Fake("ready").launch()
        app.element("sidebar-base-image").click()
        XCTAssertTrue(app.element("golden-ready-line").waitForExistence(timeout: 10))
        waitForText(app, "The base image is ready")
        XCTAssertFalse(app.buttons["Remove Base Image…"].exists)
        let toggle = app.buttons["base-image-advanced"]
        XCTAssertTrue(app.revealAnywhere(toggle))
        toggle.click()
        XCTAssertTrue(app.revealAnywhere(app.buttons["Remove Base Image…"]))
    }

    // A build is one progress with what it does now, and the four steps
    // as a checklist with one mark each.
    func testTheBuildIsOneProgressWithAChecklist() {
        let fake = Fake("first-app", env: ["PADDOCK_LAUNCHER_WELCOMED": "1"])
        let app = fake.launch()
        XCTAssertTrue(app.buttons["empty-add-app"].waitForExistence(timeout: 15))
        app.buttons["empty-add-app"].click()
        let build = app.buttons["build-button"]
        XCTAssertTrue(build.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: build)
        waitForExpectations(timeout: 15)
        build.click()
        XCTAssertTrue(app.element("build-headline").waitForExistence(timeout: 15), "\(fake.calls.map(\.line))")
        XCTAssertEqual(app.progressIndicators.matching(identifier: "build-progress").count, 1)
        for step in ["download", "install", "guided", "seal"] {
            XCTAssertTrue(app.element("step-" + step).exists, step)
        }
        XCTAssertTrue(app.element("close-note").exists)
        XCTAssertTrue(app.buttons["cancel-build"].exists)
    }

    // An old request shows its age, and the expired ones clear with one
    // button that answers No.
    func testExpiredRequestsShowTheirAgeAndClear() {
        let fake = Fake("agents")
        let app = fake.launch()
        XCTAssertTrue(app.element("sidebar-questions").waitForExistence(timeout: 15))
        app.element("sidebar-questions").click()
        let card = app.element("agent-request-r-1793959080-aa11bb22")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        // The requests of the fixture were made on 6 Nov 2026.
        let age = app.element("agent-request-age-r-1793959080-aa11bb22")
        XCTAssertTrue(age.exists)
        XCTAssertTrue(age.text.hasPrefix("Asked ") && age.text.hasSuffix(" d ago"), age.text)
        XCTAssertTrue(app.element("expired-banner").exists)
        XCTAssertTrue(app.text("expired-line").contains("older than a day or timed out"), app.text("expired-line"))
        app.buttons["clear-expired"].click()
        XCTAssertTrue(fake.waitForCall("approvals answer r-1793959080-aa11bb22 deny"), "\(fake.calls.map(\.line))")
    }

    // The Agents page with no run, on a Mac where paddock found no
    // agent: the room, the reason, Look Again and New Agent. The desktop
    // app of paddock's list (VS Code) does not count as an agent.
    func testTheEmptyAgentsPageSaysWhenNoAgentIsInstalled() {
        let app = Fake("agents-none").launch()
        XCTAssertTrue(app.element("sidebar-agents").waitForExistence(timeout: 15))
        app.element("sidebar-agents").click()
        XCTAssertTrue(app.element("agents-empty").waitForExistence(timeout: 10))
        // paddock lists its agents at launch.
        expectation(for: NSPredicate(format: "label == 'No agent found on this Mac' OR value == 'No agent found on this Mac'"),
                    evaluatedWith: app.element("agents-empty-title"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["agents-look-again"].exists)
        XCTAssertTrue(app.buttons["empty-new-agent"].isEnabled)
    }

    // With agents installed and no run yet: the usual empty page.
    func testTheEmptyAgentsPageWithAgentsInstalled() {
        let app = Fake("ready").launch()
        XCTAssertTrue(app.element("sidebar-agents").waitForExistence(timeout: 15))
        app.element("sidebar-agents").click()
        XCTAssertTrue(app.element("agents-empty").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("agents-empty-title"), "No agents yet")
        XCTAssertFalse(app.buttons["agents-look-again"].exists)
        XCTAssertTrue(app.buttons["empty-new-agent"].isEnabled)
    }
}
