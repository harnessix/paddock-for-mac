import XCTest
@testable import PaddockKit

/// The welcome window: three steps that lead to the first agent, the
/// checklist of step 2, when the window shows, and the menu that leads
/// with the agents. Nothing of it asks for the base image.
@MainActor
final class WelcomeTests: XCTestCase {
    /// The words of the base image and its virtual machines.
    static let baseImageWords = ["base image", "macvm", "virtual machine", "restore image", "25 gb", "13 gb"]

    func assertNoBaseImage(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let lower = text.lowercased()
        for word in WelcomeTests.baseImageWords {
            XCTAssertFalse(lower.contains(word), "\"\(text)\" names \"\(word)\"", file: file, line: line)
        }
    }

    func texts(_ row: PrereqRow) -> [String] {
        [row.title.english, row.result.english, row.command ?? ""]
    }

    // MARK: The steps

    func testThreeStepsThatLeadToTheFirstAgent() {
        XCTAssertEqual(WelcomeStep.allCases.map { $0.title.english },
                       ["Welcome", "Check this Mac", "Start your first agent"])
        XCTAssertEqual(WelcomeStep.allCases.map(\.rawValue), [1, 2, 3])
        XCTAssertEqual(WelcomeStep.at(0), .welcome)
        XCTAssertEqual(WelcomeStep.at(2), .check)
        XCTAssertEqual(WelcomeStep.at(9), .start)
    }

    func testNoStepAndNoLineIsAboutTheBaseImage() {
        for step in WelcomeStep.allCases { assertNoBaseImage(step.title.english) }
        assertNoBaseImage(WelcomeCopy.title.english)
        XCTAssertEqual(WelcomeCopy.points.count, 3)
        for point in WelcomeCopy.points { assertNoBaseImage(point.english) }
        assertNoBaseImage(WelcomeCopy.apps.english)
    }

    // The story of step 1 is "your computer stays yours": approval and
    // the room. It does not lead with auto-approval.
    func testStepOneDoesNotLeadWithAutoApproval() {
        XCTAssertEqual(WelcomeCopy.title.english, "Your computer stays yours")
        XCTAssertEqual(WelcomeCopy.points, [WelcomeCopy.approve, WelcomeCopy.room, WelcomeCopy.copy])
        XCTAssertTrue(WelcomeCopy.approve.english.contains("asks you before each step"))
        for text in WelcomeCopy.points.map(\.english) + [WelcomeCopy.title.english, WelcomeCopy.apps.english] {
            let lower = text.lowercased()
            for phrase in ["no prompts", "without asking", "auto-approv", "yolo", "recommended"] {
                XCTAssertFalse(lower.contains(phrase), "\"\(text)\" says \"\(phrase)\"")
            }
        }
    }

    // Step 3 lists Manual first and recommends neither mode. The mode of
    // a first start is one constant: manual.
    func testManualComesFirstAndTheDefaultIsOneConstant() {
        XCTAssertEqual(AgentMode.initial, .manual)
        XCTAssertEqual(AgentMode.manualFirst, [.manual, .auto])
        XCTAssertEqual(AgentMode.allCases, AgentMode.manualFirst)
        for mode in AgentMode.allCases {
            XCTAssertFalse(mode.title.english.lowercased().contains("recommended"), mode.title.english)
            XCTAssertEqual(mode.plainTitle, mode.title)
        }
        XCTAssertEqual(Set(AgentMode.manualFirst), Set(AgentMode.allCases))
        XCTAssertEqual(AgentMode.manualFirst.map { $0.plainTitle.english },
                       ["Ask me before each step", "Full auto in the sandbox"])
        XCTAssertEqual(AgentForm(harnesses: [], recents: []).mode, AgentMode.initial)
        XCTAssertEqual(AgentLaunch(harness: "claude", folder: "/tmp/p", network: .api, worktree: false).mode,
                       AgentMode.initial)
    }

    // MARK: Step 2

    func testPaddockRowSaysTheVersionAndTheProtocol() {
        let row = WelcomeChecks.paddockRow(binary: .ok(version: "0.2.2"), missing: false)
        XCTAssertEqual(row.kind, .paddock)
        XCTAssertEqual(row.status, .pass)
        XCTAssertEqual(row.result.english, "paddock 0.2.2 found, launcher protocol v1")
        XCTAssertTrue(WelcomeChecks.canContinue(row))
    }

    func testPaddockRowOfAPaddockThatCannotBeUsed() {
        let missing = WelcomeChecks.paddockRow(binary: nil, missing: true)
        XCTAssertEqual(missing.status, .fail)
        XCTAssertEqual(missing.command, "brew install harnessix/tap/paddock")
        XCTAssertFalse(WelcomeChecks.canContinue(missing))

        let checking = WelcomeChecks.paddockRow(binary: nil, missing: false)
        XCTAssertEqual(checking.status, .checking)
        XCTAssertFalse(WelcomeChecks.canContinue(checking))

        let old = WelcomeChecks.paddockRow(binary: .tooOld(have: "0.2.1", need: "0.2.2"), missing: false)
        XCTAssertEqual(old, Prerequisites.paddockRow(binary: .tooOld(have: "0.2.1", need: "0.2.2"), missing: false))
        XCTAssertFalse(WelcomeChecks.canContinue(old))
    }

    // Every row that step 2 can show: paddock in each state, and the
    // free space. No row of `paddock doctor`, no word of the base image.
    func testCheckRowsNeverAskForTheBaseImage() {
        let verdicts: [VersionGate.Verdict?] = [
            nil, .ok(version: "0.2.2"), .tooOld(have: "0.2.1", need: "0.2.2"), .tooNew(have: "1.0.0"),
            .unreadable(output: "?"), .incompatible(version: "0.2.2", reason: .noAnswer(status: 2)),
            .incompatible(version: "", reason: .timedOut),
        ]
        var rows = verdicts.map { WelcomeChecks.paddockRow(binary: $0, missing: false) }
        rows.append(WelcomeChecks.paddockRow(binary: nil, missing: true))
        rows.append(WelcomeChecks.spaceRow(free: 184_000_000_000))
        for row in rows {
            XCTAssertTrue(row.kind == .paddock || row.kind == .space, "\(row.kind)")
            for text in texts(row) { assertNoBaseImage(text) }
            XCTAssertFalse(row.actions.contains(.manageStorage), "the free space never blocks an agent")
        }
    }

    func testFreeSpaceRowOnlyTells() {
        let row = WelcomeChecks.spaceRow(free: 184_000_000_000)
        XCTAssertEqual(row.kind, .space)
        XCTAssertEqual(row.status, .pass)
        XCTAssertEqual(row.result.english, "184.0 GB free on this disk")
        XCTAssertEqual(WelcomeChecks.spaceRow(free: 1_000_000_000).status, .pass, "no fixed amount for an agent")
    }

    // paddock's list: the installed agents first, each with its
    // character; a missing agent with its install command.
    func testAgentsOfTheListWithHowToInstall() throws {
        let agents = WelcomeChecks.agents(try HarnessJSON.list(try Fixtures.data("list-agents.json")))
        XCTAssertEqual(agents.map(\.harness), ["claude", "codex", "gemini", "kimi", "copilot", "grok", "opencode"])
        XCTAssertFalse(agents.contains { $0.harness == "vscode" || $0.harness == "claude-desktop" }, "desktop apps are no agents")

        let claude = try XCTUnwrap(agents.first)
        XCTAssertEqual(claude.title, "Claude Code")
        XCTAssertEqual(claude.color, .orange)
        XCTAssertTrue(claude.installed)
        XCTAssertNil(claude.install)
        XCTAssertEqual(claude.result.english, "Installed")

        let copilot = try XCTUnwrap(agents.first { $0.harness == "copilot" })
        XCTAssertFalse(copilot.installed)
        XCTAssertEqual(copilot.color, .green)
        XCTAssertEqual(copilot.install, "npm install -g @github/copilot")
        XCTAssertEqual(copilot.result.english, "Not installed. Run this command in Terminal:")
        XCTAssertEqual(copilot.mark.english, "Not installed")

        // An agent whose install command the launcher does not know.
        let grok = try XCTUnwrap(agents.first { $0.harness == "grok" })
        XCTAssertNil(grok.install)
        XCTAssertEqual(grok.result.english, "Not installed. Install it in Terminal.")

        for agent in agents {
            assertNoBaseImage(agent.result.english)
            assertNoBaseImage(agent.install ?? "")
        }
    }

    func testInstallCommands() {
        XCTAssertEqual(AgentInstall.command("claude"), "npm install -g @anthropic-ai/claude-code")
        XCTAssertEqual(AgentInstall.command("codex"), "npm install -g @openai/codex")
        XCTAssertEqual(AgentInstall.command("gemini"), "npm install -g @google/gemini-cli")
        XCTAssertEqual(AgentInstall.command("opencode"), "npm install -g opencode-ai")
        XCTAssertNil(AgentInstall.command("kimi"))
    }

    func testNoAgentInstalledStillListsThem() throws {
        let agents = WelcomeChecks.agents(try HarnessJSON.list(try Fixtures.data("list-none-installed.json")))
        XCTAssertEqual(agents.map(\.harness), ["claude", "codex"])
        XCTAssertTrue(agents.allSatisfy { !$0.installed && $0.install != nil })
    }

    // MARK: When the window shows

    // A new Mac: paddock passes, nothing was built or added. The welcome
    // shows once. It runs no doctor and no setup.
    func testWelcomeShowsOnceOnANewMac() async throws {
        let h = try await Harness("fresh")
        XCTAssertEqual(h.store.golden, .none)
        XCTAssertTrue(h.store.needsOnboarding)
        XCTAssertTrue(h.calls(["macvm", "setup"]).isEmpty)
        XCTAssertTrue(h.calls(PaddockArgs.doctor).isEmpty)

        // Start or "Skip for now".
        h.store.welcomeDone = true
        XCTAssertFalse(h.store.needsOnboarding, "a missing base image alone never opens the welcome")
    }

    // The base image belongs to Add App: asked for only there, and only
    // while none is there and none is being built.
    func testOnlyAddAppAsksForTheBaseImage() async throws {
        let fresh = try await Harness("fresh")
        XCTAssertTrue(fresh.store.addNeedsBaseImage)

        let ready = try await Harness("empty")
        XCTAssertTrue(ready.store.golden.isReady)
        XCTAssertFalse(ready.store.addNeedsBaseImage)
        XCTAssertFalse(ready.store.needsOnboarding, "a Mac with a base image was used before")

        let failed = try await Harness("failed-no-space")
        XCTAssertFalse(failed.store.addNeedsBaseImage, "the failed build shows its own page")
        XCTAssertFalse(failed.store.needsOnboarding, "a build that began is past the welcome")

        let unknown = LauncherStore(service: nil)
        XCTAssertFalse(unknown.addNeedsBaseImage, "not before paddock said that none is there")
    }

    func testAnUnusablePaddockAlwaysShowsTheWelcome() async {
        let store = LauncherStore(service: nil)
        store.welcomeDone = true
        await store.start(locate: { nil }, makeService: { _ in fatalError("not called") })
        XCTAssertTrue(store.needsOnboarding)
    }

    // MARK: The menu

    func testMenuLeadsWithTheAgents() async throws {
        XCTAssertEqual(MenuModel.agentsHeader(0).english, "No agents running")
        XCTAssertEqual(MenuModel.agentsHeader(1).english, "1 agent running")
        XCTAssertEqual(MenuModel.agentsHeader(3).english, "3 agents running")

        // No app and no base image: the menu has no Apps part, so it does
        // not open with "No base image".
        let fresh = try await Harness("fresh")
        let empty = MenuModel.of(fresh.store, keepRunning: true)
        XCTAssertEqual(empty.agentsHeader.english, "No agents running")
        XCTAssertFalse(empty.showsApps)

        let ready = try await Harness("ready")
        let menu = MenuModel.of(ready.store, keepRunning: true)
        XCTAssertTrue(menu.showsApps)
        XCTAssertEqual(menu.header.english, "Base image ready")
    }
}
