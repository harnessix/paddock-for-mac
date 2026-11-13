import XCTest

/// The Rooms view of the library: the toolbar switch and its memory, one
/// element per card with the spoken state, the arrow keys and Return, the
/// primary button of a card, and the list that still works.
final class RoomsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // The library fixture, in sidebar order:
    //   sample-notes     Sample Notes, running, 3 windows
    //   sample-notes--2  Sample Notes 2, stopped
    //   sample-mail      Sample Mail, suspended

    func testRoomCardsSpeakTheirState() {
        let app = Fake("library").launch()
        XCTAssertTrue(app.element("app-row-sample-notes").waitForExistence(timeout: 10))
        app.chooseLayout("Rooms")
        let notes = app.element("room-card-sample-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10), "no room card")
        XCTAssertEqual(notes.label, "Sample Notes, Running, 3 windows")
        XCTAssertEqual(app.element("room-card-sample-notes--2").label, "Sample Notes 2, Stopped")
        XCTAssertTrue(app.element("room-card-sample-mail").label.hasPrefix("Sample Mail, Suspended"),
                      app.element("room-card-sample-mail").label)
        // One element: the art and the texts are not children of their own.
        XCTAssertEqual(notes.descendants(matching: .any).count, 0)
        // The primary button: Open for the running app, Start for the
        // stopped one, Resume for the suspended one.
        XCTAssertEqual(app.buttons["room-primary-sample-notes"].label, "Open")
        XCTAssertEqual(app.buttons["room-primary-sample-notes--2"].label, "Start")
        XCTAssertEqual(app.buttons["room-primary-sample-mail"].label, "Resume")
    }

    func testPrimaryButtonOfACardStarts() {
        let fake = Fake("library")
        let app = fake.launch()
        XCTAssertTrue(app.element("app-row-sample-notes").waitForExistence(timeout: 10))
        app.chooseLayout("Rooms")
        let start = app.buttons["room-primary-sample-notes--2"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        XCTAssertTrue(fake.waitForCall("app run sample-notes --instance 2"), "\(fake.calls.map(\.line))")
    }

    // Click a card, then Right, Right, Left: the second card; Return
    // opens its detail. Had a key been lost, Return would open another app.
    func testArrowKeysAndReturn() {
        let app = Fake("library").launch()
        XCTAssertTrue(app.element("app-row-sample-notes").waitForExistence(timeout: 10))
        app.chooseLayout("Rooms")
        let notes = app.element("room-card-sample-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let title = app.element("detail-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Return opens the detail")
        XCTAssertEqual(title.text, "Sample Notes 2")
        XCTAssertTrue(app.buttons["start-button"].exists, "the detail has its session buttons")
    }

    // Left and Up from the first card stay on it; Return then opens it.
    func testArrowKeysStopAtTheEdges() {
        let app = Fake("library").launch()
        XCTAssertTrue(app.element("app-row-sample-notes").waitForExistence(timeout: 10))
        app.chooseLayout("Rooms")
        let notes = app.element("room-card-sample-notes")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let title = app.element("detail-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.text, "Sample Notes")
    }

    // The choice is kept: the next launch with the same settings opens
    // the rooms. Back to List, the list and detail work as before.
    func testLayoutIsRememberedAndListStillWorks() {
        let suite = "dev.paddock.mac.uitest." + UUID().uuidString
        let first = Fake("library", env: ["PADDOCK_LAUNCHER_DEFAULTS": suite]).launch()
        XCTAssertTrue(first.element("app-row-sample-notes").waitForExistence(timeout: 10))
        first.chooseLayout("Rooms")
        XCTAssertTrue(first.element("room-card-sample-notes").waitForExistence(timeout: 10))
        first.terminate()

        let fake = Fake("library", env: ["PADDOCK_LAUNCHER_DEFAULTS": suite])
        let app = fake.launch()
        XCTAssertTrue(app.element("room-card-sample-notes").waitForExistence(timeout: 10), "Rooms again after a relaunch")
        app.chooseLayout("List")
        XCTAssertTrue(app.element("detail-title").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("room-card-sample-notes").exists)
        app.selectApp("sample-notes--2")
        XCTAssertEqual(app.text("detail-title"), "Sample Notes 2")
        app.buttons["start-button"].click()
        XCTAssertTrue(fake.waitForCall("app run sample-notes --instance 2"))
        app.selectApp("sample-mail")
        XCTAssertTrue(app.buttons["resume-button"].waitForExistence(timeout: 5))
        app.openTab("Log")
        XCTAssertTrue(app.element("log-text").waitForExistence(timeout: 5))
    }

    // In Rooms, Questions and Base image still show their own views.
    func testOtherSidebarItemsInRooms() {
        let app = Fake("library").launch()
        XCTAssertTrue(app.element("app-row-sample-notes").waitForExistence(timeout: 10))
        app.chooseLayout("Rooms")
        XCTAssertTrue(app.element("rooms-grid").waitForExistence(timeout: 10))
        app.element("sidebar-questions").click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.element("rooms-grid"))
        waitForExpectations(timeout: 5)
        app.selectApp("sample-mail")
        XCTAssertTrue(app.element("room-card-sample-mail").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("detail-title").exists, "Rooms shows the grid, not the detail")
    }
}

extension XCUIApplication {
    /// Picks List or Rooms in the toolbar switch; the View menu item when
    /// the switch does not show its segments to XCTest.
    func chooseLayout(_ title: String) {
        let toolbar = toolbars.firstMatch
        let candidates = [toolbar.radioButtons[title], toolbar.buttons[title], segmentedControls.buttons[title],
                          radioButtons[title]]
        for candidate in candidates where candidate.exists && candidate.isHittable {
            candidate.click()
            return
        }
        let view = menuBars.menuBarItems["View"]
        XCTAssertTrue(view.waitForExistence(timeout: 5), "no View menu")
        view.click()
        let item = menuItems["Show as " + title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no menu item Show as \(title)")
        item.click()
    }
}
