import XCTest

/// The Files screens of an agent run against the fake paddock.
///
/// The files fixture (Fixtures/files) is the agents fixture with the copy
/// commands of paddock 0.2.4 (Fixtures/copy-v1):
///   claude-1a2b3c  shop, live: 8 changes, 2 of them conflicts, 1 kept
///   gemini-111111  shop, ended: a copy with no changes
/// Both sides of the changed files come from Fixtures/files-tree, so the
/// preview shows a real diff.
final class FilesUITests: XCTestCase {
    static let tree = Fake.launcherRoot.appendingPathComponent("Fixtures/files-tree").path

    override func setUp() {
        continueAfterFailure = false
    }

    func launch(_ scenario: String = "files") -> (Fake, XCUIApplication) {
        let fake = Fake(scenario, env: ["PADDOCK_LAUNCHER_FILES_ROOT": FilesUITests.tree])
        return (fake, fake.launch())
    }

    /// Opens the Files screen of a run from its room.
    func openFiles(_ app: XCUIApplication, run: String = "claude-1a2b3c") {
        let row = app.element("agent-row-" + run)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no agent row")
        row.click()
        let open = app.buttons["files-open"]
        XCTAssertTrue(open.waitForExistence(timeout: 15), "no Files entry in the room")
        open.click()
        XCTAssertTrue(app.element("files-title").waitForExistence(timeout: 10), "the Files screen did not open")
    }

    /// The button of a confirmation: it is a sheet of the window, or a
    /// dialog, by the macOS version.
    func confirmButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[title].firstMatch
        if inSheet.waitForExistence(timeout: 5) { return inSheet }
        return app.dialogs.buttons[title].firstMatch
    }

    // MARK: The entry

    func testRoomSaysWhatWaitsInTheCopy() {
        let (_, app) = launch()
        let row = app.element("agent-row-claude-1a2b3c")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        let line = app.element("files-entry-line")
        XCTAssertTrue(line.waitForExistence(timeout: 15), "no entry bar")
        XCTAssertEqual(line.text, "7 changes wait in the copy, 2 in conflict")
        // The room itself stays: the bar is under it.
        XCTAssertTrue(app.element("agent-title").exists)
        // A run with no copy has no bar.
        app.element("agent-row-kimi-7a8b9c").click()
        XCTAssertTrue(app.element("agent-title").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("files-entry-line").exists)
    }

    /// paddock 0.2.3 has no `changes`: the room shows no Files entry.
    func testAnOlderPaddockHasNoFilesEntry() {
        let fake = Fake("agents")
        let app = fake.launch()
        let row = app.element("agent-row-claude-1a2b3c")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        XCTAssertTrue(fake.waitForCall("changes --json"), "the room asks once")
        XCTAssertTrue(app.element("agent-title").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element("files-entry").exists)
    }

    // MARK: Changes

    func testChangesTableTreeAndFilter() {
        let (_, app) = launch()
        openFiles(app)
        XCTAssertEqual(app.text("files-title"), "Files of shop")
        XCTAssertEqual(app.text("files-subtitle"), "Claude Code · 7 changes wait in the copy, 2 in conflict")
        // VoiceOver reads a row as one line.
        let cart = app.element("files-row-src/cart.ts")
        XCTAssertTrue(cart.waitForExistence(timeout: 10), "no row for src/cart.ts")
        XCTAssertEqual(cart.label, "cart.ts, changed, 12 lines added, 3 removed, the agent is writing it")
        XCTAssertEqual(app.element("files-row-docs/notes.md").label, "notes.md, new, 4 lines added")
        XCTAssertEqual(app.element("files-row-scripts/deploy.sh").label, "deploy.sh, kept in the copy, 9 lines added")
        XCTAssertEqual(app.element("files-row-src/legacy/old-cart.ts").label, "old-cart.ts, deleted, 61 lines removed")
        XCTAssertEqual(app.element("files-row-README.md").label,
                       "README.md, conflict, You changed this file after the agent started., 4 lines added, 1 removed")
        // The marks are a symbol and a word.
        for word in ["New", "Changed", "Deleted", "Conflict", "Kept"] { waitForText(app, word) }
        // The tree counts the changes in each folder.
        XCTAssertEqual(app.element("files-folder-root").label, "shop, 8 changes, 2 conflicts")
        XCTAssertEqual(app.element("files-folder-src").label, "src, 4 changes, 1 conflict")
        // A folder shows its files only.
        app.element("files-folder-src").click()
        XCTAssertTrue(app.element("files-row-src/cart.ts").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("files-row-README.md").exists)
        app.element("files-folder-root").click()
        XCTAssertTrue(app.element("files-row-README.md").waitForExistence(timeout: 5))
        // Conflicts: the two files that changed on both sides.
        app.openTab("Conflicts")
        XCTAssertTrue(app.element("files-row-src/checkout.ts").waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("files-row-src/cart.ts").exists)
        // Back leads to the room.
        app.buttons["files-back"].click()
        XCTAssertTrue(app.element("agent-title").waitForExistence(timeout: 10))
    }

    func testSearchNarrowsTheTable() {
        let (_, app) = launch()
        openFiles(app)
        XCTAssertTrue(app.element("files-row-README.md").waitForExistence(timeout: 10))
        let search = app.textFields["files-search"]
        search.click()
        search.typeText("cart")
        XCTAssertTrue(app.element("files-row-src/cart.ts").waitForExistence(timeout: 5))
        XCTAssertTrue(app.element("files-row-src/legacy/old-cart.ts").exists)
        XCTAssertFalse(app.element("files-row-README.md").exists)
        search.typeText("zzz")
        waitForText(app, "No file matches the search.")
    }

    func testEmptyCopy() {
        let (_, app) = launch()
        let row = app.element("agent-row-gemini-111111")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        let line = app.element("files-entry-line")
        XCTAssertTrue(line.waitForExistence(timeout: 15))
        XCTAssertEqual(line.text, "The copy has no changes")
        app.buttons["files-open"].click()
        XCTAssertTrue(app.element("files-empty").waitForExistence(timeout: 10))
        waitForText(app, "No changes yet")
        waitForText(app, "Your folder stays as it is.")
        XCTAssertFalse(app.buttons["files-apply-all"].isEnabled)
        XCTAssertFalse(app.buttons["files-discard-all"].isEnabled)
    }

    // MARK: Preview

    func testPreviewShowsBothSidesOfATextFile() {
        let (_, app) = launch()
        openFiles(app)
        let cart = app.element("files-row-src/cart.ts")
        XCTAssertTrue(cart.waitForExistence(timeout: 10))
        cart.click()
        XCTAssertTrue(app.element("files-preview-title").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("files-preview-title"), "cart.ts")
        XCTAssertTrue(app.element("diff-stat").waitForExistence(timeout: 10), "no diff")
        XCTAssertEqual(app.text("diff-stat"), "12 lines added, 3 removed")
        // Your file on the left, the copy's on the right.
        waitForText(app, "Your folder")
        waitForText(app, "The copy")
        waitForText(app, #"import { round } from "./money";"#)
        waitForText(app, "sum += item.price;")
        XCTAssertEqual(app.element("diff-view").label, "Changes, side by side")
        // The unified switch.
        app.element("diff-unified-toggle").click()
        let unified = NSPredicate(format: "label == %@", "Changes, unified")
        expectation(for: unified, evaluatedWith: app.element("diff-view"))
        waitForExpectations(timeout: 5)
        // The three actions of the row.
        XCTAssertTrue(app.buttons["files-row-apply"].exists)
        XCTAssertTrue(app.buttons["files-row-keep"].exists)
        XCTAssertTrue(app.buttons["files-row-discard"].exists)
    }

    func testPreviewComparesPictures() {
        let (_, app) = launch()
        openFiles(app)
        let logo = app.element("files-row-assets/logo.png")
        XCTAssertTrue(logo.waitForExistence(timeout: 10))
        logo.click()
        XCTAssertTrue(app.element("image-compare-mode").waitForExistence(timeout: 10), "no picture compare")
        app.openTab("Slider")
        XCTAssertTrue(app.element("image-slider").waitForExistence(timeout: 5))
        XCTAssertEqual(app.element("image-slider").label, "Compare slider")
        app.openTab("Side by side")
        XCTAssertFalse(app.element("image-slider").waitForExistence(timeout: 1))
    }

    // MARK: Apply

    /// Apply stays off until every conflict has a choice.
    func testApplySheetNeedsAChoiceForEachConflict() {
        let (fake, app) = launch()
        openFiles(app)
        XCTAssertTrue(app.element("files-row-README.md").waitForExistence(timeout: 10))
        app.buttons["files-apply-all"].click()
        XCTAssertTrue(app.element("apply-title").waitForExistence(timeout: 10), "no Apply sheet")
        XCTAssertEqual(app.text("apply-title"), "Apply 7 changes to shop?")
        // The writes, the deletes, then the conflicts.
        XCTAssertTrue(app.element("apply-row-src/cart.ts").exists)
        XCTAssertTrue(app.element("apply-row-src/legacy/old-cart.ts").exists)
        XCTAssertFalse(app.element("apply-row-scripts/deploy.sh").exists, "a kept change stays out of Apply All")
        waitForText(app, "1 kept change stays in the copy.")
        waitForText(app, "The agent is still writing 1 of these files.")
        let confirm = app.buttons["apply-confirm"]
        XCTAssertFalse(confirm.isEnabled, "two conflicts have no choice")
        XCTAssertEqual(app.text("apply-hint"), "Choose for 2 conflicts to go on.")
        app.buttons["conflict-README.md-merge"].click()
        XCTAssertFalse(confirm.isEnabled, "one conflict has no choice")
        XCTAssertEqual(app.text("apply-hint"), "Choose for 1 conflict to go on.")
        app.buttons["conflict-src/checkout.ts-original"].click()
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(fake.calls("apply").isEmpty, "nothing is applied before Apply")
        confirm.click()
        XCTAssertTrue(fake.waitForCall("apply claude-1a2b3c --on-conflict stop --yes --json --token t-5f2c81aa -- "))
        XCTAssertTrue(fake.waitForCall("apply claude-1a2b3c --on-conflict merge --yes --json -- README.md"))
        XCTAssertEqual(fake.calls("apply").count, 2, "the ready changes, then the merge; the file you keep needs no call")
        // The sheet goes, the line says what happened, and with no motion
        // (a UI test run, or Reduce Motion) a check mark shows on the house.
        XCTAssertFalse(app.element("apply-title").waitForExistence(timeout: 1))
        waitForText(app, "Applied 7 changes to shop. ⌘Z takes it back.")
    }

    func testApplyOfOneRowAndAStaleCopy() {
        let (fake, app) = launch("files-moved")
        openFiles(app)
        let notes = app.element("files-row-docs/notes.md")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        // ⌘↩ applies the selected file.
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.element("apply-title").waitForExistence(timeout: 10), "⌘↩ opens the Apply sheet")
        XCTAssertEqual(app.text("apply-title"), "Apply 1 change to shop?")
        app.buttons["apply-confirm"].click()
        XCTAssertTrue(fake.waitForCall("apply claude-1a2b3c --yes --json --token t-5f2c81aa -- docs/notes.md"))
        // The copy changed since: a plain sentence, and the sheet stays.
        let problem = app.element("apply-problem")
        XCTAssertTrue(problem.waitForExistence(timeout: 10))
        XCTAssertEqual(problem.text, "The copy changed since you looked. Check the list, then apply again.")
        app.buttons["apply-cancel"].click()
    }

    // MARK: Keys

    func testKeepDiscardAndUndoKeys() {
        let (fake, app) = launch()
        openFiles(app)
        let notes = app.element("files-row-docs/notes.md")
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        notes.click()
        // ⌘K keeps the file in the copy.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(fake.waitForCall("keep claude-1a2b3c --json -- docs/notes.md"), "⌘K keeps")
        waitForText(app, "Kept 1 change in the copy")
        // ⌘⌫ asks, then discards.
        notes.click()
        app.typeKey(.delete, modifierFlags: .command)
        let confirm = confirmButton(app, "Discard")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "⌘⌫ asks first")
        waitForText(app, "Discard the change of notes.md?")
        XCTAssertTrue(fake.calls("discard").isEmpty)
        confirm.click()
        XCTAssertTrue(fake.waitForCall("discard claude-1a2b3c --yes --json -- docs/notes.md"))
        waitForText(app, "Discarded 1 change")
        // ⌘Z takes the last apply back.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(fake.waitForCall("undo b-20261106-0a1b2c --yes --json"), "⌘Z undoes the last apply")
        waitForText(app, "Took the last apply back")
    }

    func testDiscardAllAsksFirst() {
        let (fake, app) = launch()
        openFiles(app)
        XCTAssertTrue(app.element("files-row-README.md").waitForExistence(timeout: 10))
        app.buttons["files-discard-all"].click()
        let confirm = confirmButton(app, "Discard")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        waitForText(app, "Discard all 8 changes of the copy?")
        confirm.click()
        XCTAssertTrue(fake.waitForCall("discard claude-1a2b3c --yes --json"))
        XCTAssertEqual(fake.calls("discard"), ["discard claude-1a2b3c --yes --json"], "Discard All names no path")
    }

    // MARK: Backups

    func testBackupsTimelineAndRestore() {
        let (fake, app) = launch()
        openFiles(app)
        app.buttons["files-backups"].click()
        XCTAssertTrue(app.element("backups-title").waitForExistence(timeout: 10), "no Backups sheet")
        XCTAssertEqual(app.text("backups-title"), "Backups of shop")
        XCTAssertTrue(fake.waitForCall("backups /Users/demo/src/shop --json"))
        let point = app.element("backup:b-20261106-0a1b2c")
        XCTAssertTrue(point.waitForExistence(timeout: 10), "no point for the last apply")
        XCTAssertTrue(point.label.contains("before an apply"), point.label)
        XCTAssertTrue(point.label.contains("Claude Code"), point.label)
        // The snapshot of a direct run is in the same timeline.
        XCTAssertTrue(app.element("snapshot:aider-333333").exists)
        for tag in ["Made by Undo", "Undone", "Whole folder", "Snapshot"] { waitForText(app, tag) }
        // Restore of a whole point asks first.
        app.buttons["backup-restore-backup:b-20261106-0a1b2c"].click()
        let confirm = confirmButton(app, "Restore")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        XCTAssertTrue(fake.calls("restore").isEmpty)
        confirm.click()
        XCTAssertTrue(fake.waitForCall("restore b-20261106-0a1b2c --yes --json"))
        app.buttons["backups-done"].click()
        XCTAssertFalse(app.element("backups-title").waitForExistence(timeout: 1))
    }

    // MARK: Pointer

    func testPointerPopoverShowsTheStore() {
        let (fake, app) = launch()
        openFiles(app)
        let chip = app.element("files-pointer-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        XCTAssertEqual(chip.label, "Copies safe")
        chip.click()
        XCTAssertTrue(app.element("pointer-title").waitForExistence(timeout: 10), "no popover")
        XCTAssertTrue(fake.waitForCall("pointer status /Users/demo/src/shop --json"))
        XCTAssertTrue(app.element("pointer-size").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("pointer-size"), "1.3 GB")
        XCTAssertEqual(app.element("pointer-encryption").label, "Encrypted")
        waitForText(app, "FileVault is on for this disk.")
        waitForText(app, "2 copies, 5 backups")
        XCTAssertEqual(app.buttons["pointer-action"].label, "Show in Finder")
    }

    /// A state that needs you has paddock's own command as its one action.
    func testPointerThatNeedsARepair() {
        let (fake, app) = launch("files-moved")
        openFiles(app)
        let chip = app.element("files-pointer-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 10))
        chip.click()
        let action = app.buttons["pointer-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        let repair = NSPredicate(format: "label == %@", "Repair")
        expectation(for: repair, evaluatedWith: action)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.text("pointer-title"), "Copies need you")
        waitForText(app, "This folder moved. Its store still names the old place.")
        XCTAssertEqual(app.text("pointer-command"), "paddock pointer adopt /Users/demo/src/shop")
        XCTAssertEqual(app.element("pointer-encryption").label, "Not encrypted")
        action.click()
        XCTAssertTrue(fake.waitForCall("pointer adopt /Users/demo/src/shop"))
    }
}
