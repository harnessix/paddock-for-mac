import XCTest

/// The terminal agents in the launcher: the Agents section, the rooms, the
/// New Agent sheet, the terminal pane, Stop with its confirmation, the
/// request cards and their answers, the menu bar and an older paddock.
///
/// The agents fixture (Fixtures/agents), most urgent first:
///   claude-1a2b3c  Claude Code in shop, waiting: an exec card and a push card
///   grok-222222    Grok in docs, failed: blocked: no API key
///   kimi-7a8b9c    Moonshot Kimi Code in notes, stuck
///   codex-4d5e6f   Codex in docs, idle
///   gemini-111111  Gemini CLI in shop, done
final class AgentsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A project folder in git, for the sheet.
    func makeProject() -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-shop-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        return folder.path
    }

    // MARK: Rooms

    func testAgentsSectionListsRunsWithTheirState() {
        let app = Fake("agents").launch()
        let claude = app.element("agent-row-claude-1a2b3c")
        XCTAssertTrue(claude.waitForExistence(timeout: 15), "no agent row")
        XCTAssertEqual(claude.label, "Claude Code in shop, Waiting for you, works on its own, 2 requests, branch paddock/claude-1a2b3c")
        XCTAssertEqual(app.element("agent-row-grok-222222").label, "Grok in docs, Failed, no API key")
        XCTAssertEqual(app.element("agent-row-kimi-7a8b9c").label, "Moonshot Kimi Code in notes, Stuck, asks before each step",
                       "a run in manual mode says so")
        // paddock does not say the mode of this run: the row says none.
        XCTAssertEqual(app.element("agent-row-codex-4d5e6f").label, "Codex in docs, Idle")
        XCTAssertEqual(app.element("agent-row-gemini-111111").label, "Gemini CLI in shop, Done")
        // The desktop app sandbox of the list is no agent room.
        XCTAssertFalse(app.element("agent-row-vscode-0f0f0f").exists)
        // The apps stay below.
        XCTAssertTrue(app.element("app-row-Sample Notes").exists)
    }

    func testAgentRoomsGridAndKeys() {
        let app = Fake("agents").launch()
        XCTAssertTrue(app.element("agent-row-claude-1a2b3c").waitForExistence(timeout: 15))
        app.chooseLayout("Rooms")
        app.element("sidebar-agents").click()
        let claude = app.element("agent-card-claude-1a2b3c")
        XCTAssertTrue(claude.waitForExistence(timeout: 10), "no agent card")
        XCTAssertEqual(claude.label, "Claude Code in shop, Waiting for you, works on its own, 2 requests, branch paddock/claude-1a2b3c")
        // One element: the art and the texts are no children of their own.
        XCTAssertEqual(claude.descendants(matching: .any).count, 0)
        XCTAssertTrue(app.element("new-agent-room-card").exists, "the last card starts an agent")
        // Click the first card, Right twice, Left: the second card (grok).
        claude.click()
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let title = app.element("agent-title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Return opens the room")
        XCTAssertEqual(title.text, "Grok in docs")
        XCTAssertEqual(app.element("agent-state").label, "Failed")
    }

    func testDetailShowsTheRun() {
        let app = Fake("agents").launch()
        let row = app.element("agent-row-claude-1a2b3c")
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        XCTAssertTrue(app.element("agent-title").waitForExistence(timeout: 10))
        XCTAssertEqual(app.text("agent-title"), "Claude Code in shop")
        // A run in full auto has the tag; manual, the default, has none.
        XCTAssertTrue(app.element("agent-auto").exists, "the auto tag")
        XCTAssertFalse(app.element("agent-manual").exists)
        waitForText(app, "paddock/claude-1a2b3c")
        waitForText(app, "3 files changed")
        // The requests of the run show in its room too.
        XCTAssertTrue(app.element("agent-request-r-1793959080-aa11bb22").exists)
        XCTAssertTrue(app.buttons["agent-stop"].exists)
        XCTAssertTrue(app.buttons["agent-open-terminal"].exists)
        // A run without the field shows what paddock is missing.
        app.element("agent-row-codex-4d5e6f").click()
        waitForText(app, "Needs a paddock with files_changed in paddock ps --json")
    }

    // MARK: New Agent

    func testNewAgentSheetStartsARunInAPaneAndStops() {
        let project = makeProject()
        let fake = Fake("agents", env: ["PADDOCK_LAUNCHER_PICK_FOLDER": project])
        let app = fake.launch()
        XCTAssertTrue(app.element("agent-row-claude-1a2b3c").waitForExistence(timeout: 15))
        app.buttons["toolbar-new-agent"].click()
        XCTAssertTrue(app.element("new-agent-sheet").waitForExistence(timeout: 10))
        // The installed agents, each with its character; the others greyed.
        let claude = app.element("new-agent-choice-claude")
        XCTAssertTrue(claude.waitForExistence(timeout: 10))
        XCTAssertEqual(claude.label, "Claude Code, installed")
        let copilot = app.element("new-agent-choice-copilot")
        XCTAssertEqual(copilot.label, "Copilot CLI, not installed")
        XCTAssertFalse(copilot.isEnabled)
        XCTAssertFalse(app.element("new-agent-choice-claude-desktop").exists, "a desktop app is not an agent")
        // The recent projects; no folder yet, so Start waits.
        XCTAssertTrue(app.element("new-agent-folder-shop").exists)
        XCTAssertFalse(app.buttons["new-agent-start"].isEnabled)
        app.element("new-agent-choice-codex").click()
        app.buttons["new-agent-choose-folder"].click()
        // The folder is in git: "Work in a new branch" can be chosen.
        let worktree = app.checkBoxes["new-agent-worktree"].exists ? app.checkBoxes["new-agent-worktree"] : app.element("new-agent-worktree")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: worktree)
        waitForExpectations(timeout: 10)
        worktree.click()
        app.element("new-agent-network-egress").click()
        // "Ask me before each step", manual mode, is the first choice and
        // the default: --no-yolo until paddock has --manual. Full auto is
        // the second choice, and it is not marked as recommended.
        let manual = app.element("new-agent-mode-manual")
        let auto = app.element("new-agent-mode-auto")
        XCTAssertTrue(manual.isSelected)
        XCTAssertFalse(auto.isSelected)
        XCTAssertLessThan(manual.frame.minY, auto.frame.minY, "Manual is the first choice")
        XCTAssertEqual(auto.label.contains("recommended"), false, auto.label)
        auto.click()
        XCTAssertTrue(auto.isSelected)
        manual.click()
        XCTAssertTrue(manual.isSelected)
        XCTAssertTrue(app.buttons["new-agent-start"].isEnabled)
        app.buttons["new-agent-start"].click()
        // paddock run with the choices of the sheet, in a pane of the window.
        XCTAssertTrue(fake.waitForCall("run --quiet codex --network egress --worktree --no-yolo", timeout: 15), "\(fake.calls.map(\.line))")
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'agent-pane-' OR identifier BEGINSWITH 'agent-terminal-'")).firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 10), "no terminal pane")
        XCTAssertEqual(app.text("agent-title"), "Codex in " + (project as NSString).lastPathComponent)
        XCTAssertEqual(app.element("agent-state").label, "Starting")
        XCTAssertTrue(app.element("agent-manual").exists, "the detail says manual mode")
        XCTAssertFalse(app.element("agent-auto").exists, "manual has no tag")
        // Stop asks first; then the pane's process ends and the room ends.
        app.buttons["agent-stop"].click()
        XCTAssertTrue(app.element("confirm-action").waitForExistence(timeout: 5))
        app.buttons["confirm-action"].click()
        // A run that you stopped says so: "Stopped", not "Ended" (FLOW1).
        let ended = NSPredicate(format: "label == 'Stopped'")
        expectation(for: ended, evaluatedWith: app.element("agent-state"))
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["agent-close"].exists)
    }

    // ⌘N in the Agents section starts an agent; elsewhere it adds an app.
    func testCommandNFollowsTheSection() {
        let app = Fake("agents", env: ["PADDOCK_LAUNCHER_PICK_APP": "/Applications/Notebook.app"]).launch()
        XCTAssertTrue(app.element("agent-row-codex-4d5e6f").waitForExistence(timeout: 15))
        app.element("agent-row-codex-4d5e6f").click()
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.element("new-agent-sheet").waitForExistence(timeout: 10))
        // The agent of the selected room is the one chosen.
        let codex = app.element("new-agent-choice-codex")
        XCTAssertTrue(codex.waitForExistence(timeout: 10))
        XCTAssertTrue(codex.isSelected)
        app.typeKey(.escape, modifierFlags: [])
        app.selectApp("Sample Notes")
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(app.element("new-agent-sheet").waitForExistence(timeout: 3))
    }

    func testAFolderDropOpensTheSheetWithIt() {
        let project = makeProject()
        let app = Fake("agents", env: ["PADDOCK_LAUNCHER_DROP": project]).launch()
        XCTAssertTrue(app.element("new-agent-sheet").waitForExistence(timeout: 15))
        let name = (project as NSString).lastPathComponent
        XCTAssertTrue(app.element("new-agent-folder-" + name).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["new-agent-start"].isEnabled, "the agent of the last project and the dropped folder")
    }

    // MARK: Stop

    func testCommandPeriodStopsWithAConfirmation() {
        let fake = Fake("agents")
        let app = fake.launch()
        XCTAssertTrue(app.element("agent-row-codex-4d5e6f").waitForExistence(timeout: 15))
        app.element("agent-row-codex-4d5e6f").click()
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5), "⌘. asks first")
        XCTAssertTrue(fake.calls("stop").isEmpty)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(fake.calls("stop").isEmpty, "Cancel stops nothing")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.buttons["confirm-action"].waitForExistence(timeout: 5))
        app.buttons["confirm-action"].click()
        XCTAssertTrue(fake.waitForCall("stop codex-4d5e6f"), "\(fake.calls.map(\.line))")
    }

    func testOpenInTerminalHandsTheRunOver() {
        let app = Fake("agents").launch()
        XCTAssertTrue(app.element("agent-row-kimi-7a8b9c").waitForExistence(timeout: 15))
        app.element("agent-row-kimi-7a8b9c").click()
        XCTAssertTrue(app.buttons["agent-open-terminal"].waitForExistence(timeout: 10))
        app.buttons["agent-open-terminal"].click()
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("paddock-views/paddock-view-kimi-7a8b9c.command")
        let end = Date().addingTimeInterval(5)
        while Date() < end, !FileManager.default.fileExists(atPath: file.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let script = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        XCTAssertTrue(script.contains("view kimi-7a8b9c --write"), script)
    }

    // MARK: Requests

    func testRequestCardsShowNextToQuestionsAndAnswer() {
        let fake = Fake("agents")
        let app = fake.launch()
        XCTAssertTrue(app.element("sidebar-questions").waitForExistence(timeout: 15))
        app.element("sidebar-questions").click()
        let exec = app.element("agent-request-r-1793959080-aa11bb22")
        XCTAssertTrue(exec.waitForExistence(timeout: 10), "no agent card")
        // The card of the video: the pill, the question, the command.
        XCTAssertEqual(app.text("agent-request-pill-r-1793959080-aa11bb22"), "Approval needed")
        XCTAssertEqual(app.text("agent-request-question-r-1793959080-aa11bb22"), "Claude Code wants to run a command on your Mac")
        waitForText(app, "npm publish --dry-run")
        XCTAssertTrue(app.element("agent-request-left-r-1793959080-aa11bb22").exists, "the time left")
        // The app question is still there, next to it.
        XCTAssertTrue(app.element("question-r-shown-g1").exists)
        // The push card has no session answer: paddock allows none.
        XCTAssertTrue(app.buttons["agent-answer-once-r-1793959140-cc33dd44"].exists)
        XCTAssertFalse(app.buttons["agent-answer-session-r-1793959140-cc33dd44"].exists)
        app.buttons["agent-answer-session-r-1793959080-aa11bb22"].click()
        XCTAssertTrue(fake.waitForCall("approvals answer r-1793959080-aa11bb22 session"), "\(fake.calls.map(\.line))")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: exec)
        waitForExpectations(timeout: 10)
        app.buttons["agent-answer-deny-r-1793959140-cc33dd44"].click()
        XCTAssertTrue(fake.waitForCall("approvals answer r-1793959140-cc33dd44 deny"))
    }

    /// Fixtures/requests-expired: the exec card of a week ago, the push
    /// card, a live request of agy to open a sign-in page, and an exec of
    /// agy that timed out five minutes ago.
    func testAnExpiredCardIsReadOnlyAndAPageShowsItsHost() {
        let fake = Fake("requests-expired")
        let app = fake.launch()
        XCTAssertTrue(app.element("sidebar-questions").waitForExistence(timeout: 15))
        app.element("sidebar-questions").click()
        // Expired: the pill says so, a line says nobody can answer, and
        // Clear is the only action.
        let old = "r-timed-out-agy"
        XCTAssertTrue(app.element("agent-request-" + old).waitForExistence(timeout: 10), "no expired card")
        XCTAssertEqual(app.text("agent-request-pill-" + old), "Expired")
        XCTAssertTrue(app.element("agent-request-expired-" + old).exists, "no expired line")
        for answer in ["deny", "once", "session"] {
            XCTAssertFalse(app.buttons["agent-answer-\(answer)-\(old)"].exists, "an expired card has no \(answer)")
        }
        XCTAssertFalse(app.element("agent-request-left-" + old).exists, "no time left on an expired card")
        // The live web page: the host in a sentence, the address under a
        // disclosure, no scroll box.
        let url = "r-live-url-agy"
        let card = app.element("agent-request-" + url)
        XCTAssertTrue(card.exists, "no live card")
        XCTAssertTrue(app.text("agent-request-question-" + url).hasSuffix("wants to open accounts.google.com in your browser"),
                      app.text("agent-request-question-" + url))
        XCTAssertFalse(app.element("agent-request-command-" + url).exists, "no code box for a web page")
        XCTAssertEqual(card.scrollViews.count, 0, "no horizontal scroll box in the card")
        XCTAssertTrue(app.buttons["agent-answer-once-" + url].exists)
        let address = app.element("agent-request-address-" + url)
        XCTAssertTrue(address.exists, "no Full address disclosure")
        XCTAssertFalse(app.element("agent-request-link-" + url).exists, "the address is closed at first")
        let toggle = address.disclosureTriangles.firstMatch.exists ? address.disclosureTriangles.firstMatch : address
        toggle.click()
        let link = app.element("agent-request-link-" + url)
        XCTAssertTrue(link.waitForExistence(timeout: 5), "the disclosure shows the full address")
        XCTAssertTrue(link.text.hasPrefix("https://accounts.google.com/o/oauth2/auth?"), link.text)
        XCTAssertGreaterThan(link.frame.height, 30, "the address wraps over lines")
        // Clear answers No, and the card goes.
        app.buttons["agent-request-clear-" + old].click()
        XCTAssertTrue(fake.waitForCall("approvals answer \(old) deny"), "\(fake.calls.map(\.line))")
    }

    // MARK: Menu bar

    func testMenuBarListsRunningAgentsAndRequests() {
        let app = Fake("agents").launch()
        XCTAssertTrue(app.element("agent-row-claude-1a2b3c").waitForExistence(timeout: 15))
        app.openStatusMenu()
        XCTAssertTrue(app.menuItems["Claude Code in shop — Waiting for you · 2 requests"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Codex in docs — Idle"].exists)
        XCTAssertFalse(app.menuItems["Gemini CLI in shop — Done"].exists, "only running agents")
        XCTAssertTrue(app.menuItems["Agent requests… (2)"].exists)
        XCTAssertTrue(app.menuItems["New Agent…"].exists)
    }

    // MARK: An older paddock

    func testAnOlderPaddockShowsWhatItNeeds() {
        let app = Fake("agents-old-cli").launch()
        XCTAssertTrue(app.element("sidebar-agents").waitForExistence(timeout: 15))
        app.element("sidebar-agents").click()
        XCTAssertTrue(app.element("agents-empty").waitForExistence(timeout: 10))
        waitForText(app, "Needs a paddock with paddock board --json")
        app.element("empty-new-agent").click()
        XCTAssertTrue(app.element("new-agent-sheet").waitForExistence(timeout: 10))
        waitForText(app, "Needs a paddock with paddock recent --json")
    }

    func testNoAgentInstalled() {
        let app = Fake("agents-none").launch()
        XCTAssertTrue(app.element("sidebar-new-agent").waitForExistence(timeout: 15))
        app.element("sidebar-new-agent").click()
        XCTAssertTrue(app.element("new-agent-sheet").waitForExistence(timeout: 10))
        XCTAssertEqual(app.element("new-agent-choice-claude").label, "Claude Code, not installed")
        waitForText(app, "No agent is installed yet.")
        XCTAssertFalse(app.buttons["new-agent-start"].isEnabled)
    }
}
