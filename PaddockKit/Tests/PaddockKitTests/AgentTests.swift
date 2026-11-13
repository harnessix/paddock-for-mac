import XCTest
@testable import PaddockKit

/// A pane process that records what the store asks of it.
@MainActor
final class FakeAgentProcess: AgentProcess {
    var command: AgentCommand?
    var terminations = 0
    var onExit: ((Int32?) -> Void)?

    func start(_ command: AgentCommand) { self.command = command }
    func terminate() { terminations += 1 }
    /// The process ends, as paddock run would.
    func exit(_ code: Int32?) { onExit?(code) }
}

/// The agent rooms: the JSON of list, recent, ps, board and approvals, the
/// state mapping, the New Agent sheet, the panes, the request cards, the
/// menu bar items and the notifications.
@MainActor
final class AgentTests: XCTestCase {
    let environment = ["SHELL": "/bin/zsh", "HOME": "/Users/demo", "PATH": "/usr/bin:/bin", "LANG": "de_DE.UTF-8"]

    /// The agents scenario, with its agent store and the fake processes.
    struct Agents {
        let h: Harness
        let agents: AgentStore
        let processes: Box
    }

    final class Box {
        var list: [FakeAgentProcess] = []
    }

    func make(_ scenario: String = "agents", load: Bool = true) async throws -> Agents {
        let h = try await Harness(scenario)
        let box = Box()
        let agents = AgentStore(launcher: h.store, environment: environment,
                                paddockPath: { "/opt/homebrew/bin/paddock" },
                                makeProcess: { _ in
                                    let process = FakeAgentProcess()
                                    box.list.append(process)
                                    return process
                                })
        if load {
            await agents.loadChoices()
            await agents.refreshRuns(force: true)
        }
        return Agents(h: h, agents: agents, processes: box)
    }

    // MARK: JSON

    func testListKeepsTerminalAgentsAndTheirInstallState() throws {
        let all = try HarnessJSON.list(Fixtures.data("list-agents.json"))
        XCTAssertEqual(all.count, 9)
        let claude = try XCTUnwrap(all.first { $0.name == "claude" })
        XCTAssertTrue(claude.installed)
        XCTAssertFalse(claude.app)
        XCTAssertEqual(claude.summary, "Anthropic Claude Code")
        XCTAssertTrue(try XCTUnwrap(all.first { $0.name == "claude-desktop" }).app)
        XCTAssertFalse(try XCTUnwrap(all.first { $0.name == "copilot" }).installed)
        // Another api_version is not this list.
        XCTAssertThrowsError(try HarnessJSON.list(Data(#"{"api_version":"paddock.other/v1","harnesses":[]}"#.utf8)))
        // A key twice is refused, as for the launcher protocol.
        XCTAssertThrowsError(try HarnessJSON.list(Data(#"{"harnesses":[],"harnesses":[]}"#.utf8)))
    }

    func testRecentReadsObjectsAndPaths() throws {
        let recents = try RecentProjectJSON.list(Fixtures.data("recent-agents.json"))
        XCTAssertEqual(recents.map(\.path), ["/Users/demo/src/shop", "/Users/demo/src/docs", "/Users/demo/src/notes"])
        XCTAssertEqual(recents[0].harness, "claude")
        XCTAssertEqual(recents[0].last, Date(timeIntervalSince1970: 1_793_958_000))
        XCTAssertNil(recents[2].harness)
        XCTAssertEqual(try RecentProjectJSON.list(Fixtures.data("recent-empty.json")), [])
    }

    func testPsReadsRunsAndEndedRuns() throws {
        let ps = try PsJSON.decode(Fixtures.data("ps-agents.json"))
        XCTAssertEqual(ps.sandboxes.map(\.id), ["claude-1a2b3c", "codex-4d5e6f", "kimi-7a8b9c", "vscode-0f0f0f"])
        let claude = ps.sandboxes[0]
        XCTAssertEqual(claude.harness, "claude")
        XCTAssertEqual(claude.project, "/Users/demo/src/shop")
        XCTAssertEqual(claude.branch, "paddock/claude-1a2b3c")
        XCTAssertEqual(claude.started, ISO.date("2026-11-06T09:40:00Z"))
        XCTAssertEqual(claude.network, "api")
        XCTAssertEqual(claude.filesChanged, 3)
        XCTAssertEqual(claude.activity, "Editing src/cart.ts")
        XCTAssertNil(claude.idleSince)
        XCTAssertFalse(claude.stuck)
        XCTAssertEqual(ps.sandboxes[1].idleSince, ISO.date("2026-11-06T09:50:00Z"))
        XCTAssertNil(ps.sandboxes[1].filesChanged)
        XCTAssertTrue(ps.sandboxes[2].stuck)
        XCTAssertEqual(ps.ended.map(\.id), ["gemini-111111", "grok-222222"])
        XCTAssertEqual(ps.ended[1].exitCode, 1)
        XCTAssertEqual(ps.ended[1].reason, "blocked: no API key")
        XCTAssertEqual(try PsJSON.decode(Fixtures.data("ps-empty.json")), PsJSON())
        // ISO times and a list of file names read too.
        let iso = try PsJSON.decode(Data(#"{"sandboxes":[{"id":"x","harness":"codex","started":"2026-11-06T09:00:00Z","files_changed":["a.swift","b.swift"]}]}"#.utf8))
        XCTAssertEqual(iso.sandboxes[0].started, ISO.date("2026-11-06T09:00:00Z"))
        XCTAssertEqual(iso.sandboxes[0].filesChanged, 2)
        XCTAssertEqual(iso.sandboxes[0].files, ["a.swift", "b.swift"])
    }

    func testBoardGivesEachRunItsWord() throws {
        let board = try BoardJSON.decode(Fixtures.data("board-agents.json"))
        XCTAssertEqual(board.approvalsWaiting, 1)
        XCTAssertEqual(board.runs["claude-1a2b3c"]?.state, "waiting")
        XCTAssertEqual(board.runs["claude-1a2b3c"]?.project, "/Users/demo/src/shop")
        XCTAssertEqual(board.runs["gemini-111111"]?.state, "done")
        XCTAssertEqual(board.runs["codex-4d5e6f"]?.state, "idle")
        // A ticket that names its runs by id gives them its state.
        let byID = try BoardJSON.decode(Data(#"{"version":1,"projects":[{"path":"/p","tickets":[{"id":"T1","state":"blocked","runs":["r1"]}]}]}"#.utf8))
        XCTAssertEqual(byID.runs["r1"]?.state, "blocked")
        XCTAssertEqual(try BoardJSON.decode(Fixtures.data("board-empty.json")).runs, [:])
    }

    func testApprovalsSplitAgentRequestsFromAppQuestions() throws {
        let approvals = try Fixtures.decode(ApprovalsJSON.self, "approvals-agents.json")
        XCTAssertEqual(approvals.questions.map(\.id), ["r-shown-g1"])
        XCTAssertEqual(approvals.questions.first?.app, "Sample Notes")
        XCTAssertEqual(approvals.requests.map(\.id), ["r-1793959080-aa11bb22", "r-1793959140-cc33dd44"])
        let exec = approvals.requests[0]
        XCTAssertEqual(exec.sandbox, "claude-1a2b3c")
        XCTAssertEqual(exec.capability, "exec")
        XCTAssertEqual(exec.detail, "npm publish --dry-run")
        XCTAssertEqual(exec.reason, "Check the package before the release")
        XCTAssertEqual(exec.created, ISO.date("2026-11-06T09:58:00Z"))
        XCTAssertTrue(exec.sessionAllowed)
        let push = approvals.requests[1]
        XCTAssertNil(push.expires, "0 is no time limit")
        XCTAssertNil(push.reason, "an empty reason is none")
        XCTAssertFalse(push.sessionAllowed)
        // The paddock v1 fixture has only connect cards: no requests.
        XCTAssertEqual(try Fixtures.decode(ApprovalsJSON.self, "approvals-paddock-v1.json").requests, [])
        // A card with odd fields still shows: a time that is not a
        // number is no time, a missing sandbox is empty.
        let odd = try PaddockJSON.decoder.decode(ApprovalsJSON.self, from: Data(#"{"v":1,"pending":[{"id":"x","capability":"device","created":"yesterday","choices":"once"},{"id":"r1","sandbox":"s","capability":"exec","created":1,"expires":0}]}"#.utf8))
        XCTAssertEqual(odd.requests.map(\.id), ["x", "r1"])
        XCTAssertNil(odd.requests[0].created)
        XCTAssertEqual(odd.requests[0].sandbox, "")
        XCTAssertEqual(odd.requests[0].choices, [])
    }

    // MARK: State mapping

    func testStateMappingFromPsBoardAndRequests() {
        let run = AgentRunJSON(id: "r", harness: "claude")
        XCTAssertEqual(AgentStateMapper.running(run, board: nil, requests: 0), .working)
        XCTAssertEqual(AgentStateMapper.running(run, board: nil, requests: 2), .waiting(2))
        var idle = run
        idle.idleSince = Date()
        XCTAssertEqual(AgentStateMapper.running(idle, board: nil, requests: 0), .idle)
        var stuck = run
        stuck.stuck = true
        XCTAssertEqual(AgentStateMapper.running(stuck, board: nil, requests: 0), .stuck)
        // The board wins over the ps fields, the requests over the board.
        XCTAssertEqual(AgentStateMapper.running(idle, board: BoardRunJSON(id: "r", state: "working"), requests: 0), .working)
        XCTAssertEqual(AgentStateMapper.running(run, board: BoardRunJSON(id: "r", state: "blocked", status: "blocked: no key"), requests: 0),
                       .failed("no key"))
        XCTAssertEqual(AgentStateMapper.running(run, board: BoardRunJSON(id: "r", state: "idle"), requests: 1), .waiting(1))
        // A run that ps lists has not ended, whatever the board said.
        XCTAssertEqual(AgentStateMapper.running(run, board: BoardRunJSON(id: "r", state: "ended"), requests: 0), .idle)

        let ended = EndedRunJSON(id: "e", harness: "codex", exitCode: 0)
        XCTAssertEqual(AgentStateMapper.ended(ended, board: nil), .ended(done: false))
        XCTAssertEqual(AgentStateMapper.ended(EndedRunJSON(id: "e", harness: "codex", exitCode: 2), board: nil), .failed(nil))
        XCTAssertEqual(AgentStateMapper.ended(EndedRunJSON(id: "e", harness: "codex", exitCode: 0, reason: "done: shipped"), board: nil),
                       .ended(done: true))
        XCTAssertEqual(AgentStateMapper.ended(ended, board: BoardRunJSON(id: "e", state: "done")), .ended(done: true))
        XCTAssertEqual(AgentStateMapper.pane(exit: nil, running: true), .starting)
        XCTAssertEqual(AgentStateMapper.pane(exit: 0, running: false), .ended(done: false))
        XCTAssertEqual(AgentStateMapper.pane(exit: 1, running: false), .failed(nil))
        XCTAssertEqual(AgentStateMapper.pane(exit: 143, running: false, stopped: true), .ended(done: false))

        // The states map to the five loops of the art, as in the TUI.
        XCTAssertEqual(AgentState.working.pose, .work)
        XCTAssertEqual(AgentState.waiting(1).pose, .wait)
        XCTAssertEqual(AgentState.idle.pose, .idle)
        XCTAssertEqual(AgentState.ended(done: true).pose, .sleep)
        XCTAssertEqual(AgentState.failed(nil).pose, .blocked)
        XCTAssertEqual(AgentState.waiting(2).line.english, "Waiting for you · 2 requests")
        XCTAssertEqual(AgentState.failed("no key").line.english, "Failed · no key")
    }

    func testCharacterColorsFollowTheAgent() {
        XCTAssertEqual(AgentCharacter.color("claude"), .orange)
        XCTAssertEqual(AgentCharacter.color("codex"), .blue)
        XCTAssertEqual(AgentCharacter.color("gemini"), .purple)
        XCTAssertEqual(AgentCharacter.color("copilot"), .green)
        XCTAssertEqual(AgentCharacter.color("grok"), .pink)
        XCTAssertEqual(AgentCharacter.color("opencode"), .teal)
        XCTAssertEqual(AgentCharacter.color("kimi"), .gray)
        XCTAssertEqual(AgentCharacter.title("claude"), "Claude Code")
        XCTAssertEqual(AgentCharacter.title("kimi", summary: "Moonshot Kimi Code"), "Moonshot Kimi Code")
    }

    func testRoomsOfTheScenario() async throws {
        let a = try await make()
        let rooms = a.agents.rooms
        // What needs you first: waiting, failed, stuck, idle, done. The
        // app sandbox of vscode is not an agent room.
        XCTAssertEqual(rooms.map(\.key), ["claude-1a2b3c", "grok-222222", "kimi-7a8b9c", "codex-4d5e6f", "gemini-111111"])
        XCTAssertEqual(rooms.map(\.state), [.waiting(2), .failed("no API key"), .stuck, .idle, .ended(done: true)])
        XCTAssertEqual(rooms.map(\.color), [.orange, .pink, .gray, .blue, .purple])
        let claude = rooms[0]
        XCTAssertEqual(claude.requests.count, 2)
        XCTAssertEqual(claude.projectName, "shop")
        XCTAssertEqual(claude.filesChanged, 3)
        XCTAssertTrue(claude.canStop)
        XCTAssertFalse(rooms[4].canStop)
        // The scene: the wait loop with the request count on the bubble.
        let scene = claude.scene(index: 0)
        XCTAssertEqual(scene.pose, .wait)
        XCTAssertEqual(scene.badge, 2)
        XCTAssertEqual(scene.color, .orange)
        XCTAssertEqual(rooms[1].scene(index: 1).pose, .blocked)
        XCTAssertEqual(rooms[4].scene(index: 4).pose, .sleep)
        // One spoken line per room.
        XCTAssertEqual(AgentCopy.spoken(claude),
                       "Claude Code in shop, Waiting for you, works on its own, 2 requests, branch paddock/claude-1a2b3c")
        XCTAssertEqual(AgentCopy.spoken(rooms[1]), "Grok in docs, Failed, no API key")
        XCTAssertEqual(a.agents.gaps, [])
    }

    func testMissingCommandsShowWhatPaddockNeeds() async throws {
        let a = try await make("agents-old-cli")
        XCTAssertEqual(a.agents.gaps, [.recent, .board])
        XCTAssertTrue(a.agents.runsLoaded)
        XCTAssertEqual(AgentGap.board.line.english, "Needs a paddock with paddock board --json")
        XCTAssertEqual(AgentCopy.files(nil).english, "Needs a paddock with files_changed in paddock ps --json")
        XCTAssertEqual(AgentCopy.files(1).english, "1 file changed")
        // A paddock that read once keeps its runs after one failed read.
        let ok = try await make()
        ok.h.runner.reset(prefix: "ps --json")
        ok.h.runner.on(["ps", "--json"], json: "", status: 1)
        await ok.agents.refreshRuns(force: true)
        XCTAssertFalse(ok.agents.gaps.contains(.ps))
        XCTAssertEqual(ok.agents.runs.count, 3)
    }

    func testNoCallsWithoutACheckedPaddock() async throws {
        let a = try await make("protocol-none", load: false)
        await a.agents.loadChoices()
        await a.agents.refreshRuns(force: true)
        await a.agents.tick()
        for args in [AgentArgs.list, AgentArgs.recent, AgentArgs.ps, AgentArgs.board] {
            XCTAssertTrue(a.h.calls(args).isEmpty, "\(args) ran")
        }
        XCTAssertNil(a.agents.start(AgentLaunch(harness: "claude", folder: "/tmp")))
        XCTAssertTrue(a.processes.list.isEmpty)
    }

    // MARK: The New Agent sheet

    /// A later paddock may give the install command of a profile in its list:
    /// that command wins over the launcher's own. An agent without one
    /// says to install it by hand. No text asks for a newer paddock.
    func testSheetShowsTheInstallCommandOfTheProfile() throws {
        let list = #"""
        {"api_version":"paddock.list/v1","harnesses":[
          {"name":"claude","description":"Anthropic Claude Code","exe":"/u/bin/claude","installed":true,"app":false},
          {"name":"copilot","description":"GitHub Copilot CLI","exe":null,"installed":false,"app":false,
           "install":"npm install -g @github/copilot@latest\nthen log in"},
          {"name":"agy","description":"Google Antigravity CLI","exe":null,"installed":false,"app":false,
           "install":{"command":"brew install --cask antigravity"}},
          {"name":"devin","description":"Devin CLI","exe":null,"installed":false,"app":false,"install":null}
        ]}
        """#
        let harnesses = try HarnessJSON.list(Data(list.utf8))
        XCTAssertEqual(harnesses.map(\.install), [nil, "npm install -g @github/copilot@latest",
                                                  "brew install --cask antigravity", nil])
        let form = AgentForm(harnesses: harnesses, recents: [])
        let copilot = try XCTUnwrap(form.choices.first { $0.harness == "copilot" })
        XCTAssertEqual(copilot.install, "npm install -g @github/copilot@latest", "the first line of the profile's command")
        XCTAssertEqual(copilot.hint, AgentCopy.installHintCommand)
        let agy = try XCTUnwrap(form.choices.first { $0.harness == "agy" })
        XCTAssertEqual(agy.install, "brew install --cask antigravity")
        let devin = try XCTUnwrap(form.choices.first { $0.harness == "devin" })
        XCTAssertNil(devin.install)
        XCTAssertEqual(devin.hint, AgentCopy.installHintManual, "no command known: install by hand")
        XCTAssertFalse(devin.hint?.english.contains("newer paddock") ?? true)
        XCTAssertEqual(form.installedChoices.map(\.harness), ["claude"])
        XCTAssertEqual(Set(form.otherChoices.map(\.harness)), ["copilot", "agy", "devin"])
        // The welcome window shows the same command.
        let checks = WelcomeChecks.agents(harnesses)
        XCTAssertEqual(checks.first { $0.harness == "agy" }?.install, "brew install --cask antigravity")
    }

    /// The sheet has rows for three recent folders, so the folder, the
    /// mode and Start show without a scroll. The others are in a menu; a
    /// folder chosen there takes the last row.
    func testSheetShowsThreeFolderRowsAndTheChosenOne() {
        let recents = (1...6).map { RecentProjectJSON(path: "/Users/demo/src/p\($0)") }
        var form = AgentForm(harnesses: [], recents: recents)
        XCTAssertEqual(form.shownFolders.map(\.name), ["p1", "p2", "p3"])
        XCTAssertEqual(form.moreFolders.map(\.name), ["p4", "p5", "p6"])
        form.choose(folder: "/Users/demo/src/p5")
        XCTAssertEqual(form.shownFolders.map(\.name), ["p1", "p2", "p5"])
        XCTAssertEqual(form.moreFolders.map(\.name), ["p3", "p4", "p6"])
        // A new folder goes on top of the list, and so in the rows.
        form.choose(folder: "/tmp/new")
        XCTAssertEqual(form.shownFolders.map(\.name), ["new", "p1", "p2"])
        XCTAssertEqual(form.folder, "/tmp/new")
        XCTAssertEqual(AgentForm(harnesses: [], recents: Array(recents.prefix(2))).moreFolders, [])
    }

    func testSheetListsAgentsWithTheirCharacters() throws {
        let harnesses = try HarnessJSON.list(Fixtures.data("list-agents.json"))
        let recents = try RecentProjectJSON.list(Fixtures.data("recent-agents.json"))
        var form = AgentForm(harnesses: harnesses, recents: recents)
        // The known six first, then the others; no desktop app.
        XCTAssertEqual(form.choices.map(\.harness), ["claude", "codex", "gemini", "copilot", "grok", "opencode", "kimi"])
        XCTAssertEqual(form.choices.map(\.color), [.orange, .blue, .purple, .green, .pink, .teal, .gray])
        XCTAssertEqual(form.choices.filter(\.installed).map(\.harness), ["claude", "codex", "gemini", "kimi"])
        let copilot = try XCTUnwrap(form.choices.first { $0.harness == "copilot" })
        // paddock 0.2.3 gives no install command: the launcher's own one
        // shows, and where it knows none, the line says to install by hand.
        XCTAssertEqual(copilot.install, "npm install -g @github/copilot")
        XCTAssertEqual(copilot.hint, AgentCopy.installHintCommand)
        let grok = try XCTUnwrap(form.choices.first { $0.harness == "grok" })
        XCTAssertNil(grok.install)
        XCTAssertEqual(grok.hint, AgentCopy.installHintManual)
        XCTAssertFalse(grok.hint?.english.contains("newer paddock") ?? true)
        XCTAssertEqual(copilot.spoken.english, "Copilot CLI, not installed")
        XCTAssertNil(form.choices.first?.hint)
        XCTAssertNil(form.choices.first?.install, "an installed agent has no install command")
        // The grid has the installed agents; the others are under the disclosure.
        XCTAssertEqual(form.installedChoices.map(\.harness), ["claude", "codex", "gemini", "kimi"])
        XCTAssertEqual(form.otherChoices.map(\.harness), ["copilot", "grok", "opencode"])
        // The agent of the last project is chosen; a greyed tile cannot be.
        XCTAssertEqual(form.harness, "claude")
        form.choose(harness: "copilot")
        XCTAssertEqual(form.harness, "claude")
        form.choose(harness: "codex")
        XCTAssertEqual(form.harness, "codex")
        // The folders: the recent projects, no folder chosen yet.
        XCTAssertEqual(form.folders.map(\.name), ["shop", "docs", "notes"])
        XCTAssertNil(form.folder)
        XCTAssertEqual(form.missing?.english, "Choose a project folder.")
        XCTAssertNil(form.launch)
    }

    func testSheetOptionsToArguments() throws {
        let harnesses = try HarnessJSON.list(Fixtures.data("list-agents.json"))
        var form = AgentForm(harnesses: harnesses, recents: [])
        // A folder from Choose Folder… or a drop goes on top.
        form.choose(folder: "/Users/demo/src/shop/", isGit: true)
        XCTAssertEqual(form.folder, "/Users/demo/src/shop")
        XCTAssertEqual(form.folders.first?.path, "/Users/demo/src/shop")
        XCTAssertTrue(form.canStart)
        XCTAssertEqual(form.network, .api, "the default: only its AI service")
        // No mode chosen: the agent asks before each step.
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "claude", "--network", "api", "--no-yolo"])
        XCTAssertEqual(form.launch?.folder, "/Users/demo/src/shop")
        form.worktree = true
        form.network = .egress
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "claude", "--network", "egress", "--worktree", "--no-yolo"])
        form.network = .none
        form.choose(harness: "gemini")
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "gemini", "--network", "none", "--worktree", "--no-yolo"])
        // A folder that is not in git has no "new branch".
        form.choose(folder: "/Users/demo/Desktop", isGit: false)
        XCTAssertFalse(form.worktree)
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "gemini", "--network", "none", "--no-yolo"])
        form.worktree = true
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "gemini", "--network", "none", "--no-yolo"], "--worktree only in git")
        // Full auto, the opt-in, has no flag: paddock's own default.
        form.choose(mode: .auto)
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "gemini", "--network", "none"])
        // The plain words of the network levels.
        XCTAssertEqual(AgentNetwork.allCases.map(\.title.english), ["No network", "Only its AI service", "The internet"])
        // The sheet asked for one agent, from a folder drop.
        let dropped = AgentForm(harnesses: harnesses, recents: [], preferredHarness: "codex", folder: "/tmp/x")
        XCTAssertEqual(dropped.harness, "codex")
        XCTAssertEqual(dropped.folder, "/tmp/x")
    }

    func testManualModeAsksBeforeEachStep() async throws {
        // The flag: --manual once paddock has it, else --no-yolo.
        XCTAssertEqual(AgentMode.manualFlag(runHelp: String(decoding: try Fixtures.data("run-help.out"), as: UTF8.self)), "--no-yolo")
        XCTAssertEqual(AgentMode.manualFlag(runHelp: String(decoding: try Fixtures.data("run-help-manual.out"), as: UTF8.self)), "--manual")
        XCTAssertEqual(AgentMode.manualFlag(runHelp: nil), "--no-yolo")
        // Manual is the first choice, and no mode is marked as recommended.
        XCTAssertEqual(AgentMode.allCases.map(\.title.english), ["Ask me before each step", "Full auto in the sandbox"])
        XCTAssertEqual(AgentMode.initial, .manual)
        // The sheet: manual by default, with the flag; full auto has none.
        var form = AgentForm(harnesses: try HarnessJSON.list(Fixtures.data("list-agents.json")), recents: [])
        form.choose(folder: "/Users/demo/src/shop", isGit: true)
        XCTAssertEqual(form.mode, .manual)
        XCTAssertEqual(form.launch?.args(manualFlag: "--manual"), ["run", "--quiet", "claude", "--network", "api", "--manual"])
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "claude", "--network", "api", "--no-yolo"])
        form.mode = .auto
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "claude", "--network", "api"])
        XCTAssertEqual(form.launch?.args(manualFlag: "--manual"), ["run", "--quiet", "claude", "--network", "api"])
        form.mode = .manual
        XCTAssertEqual(form.launch?.args(manualFlag: "--manual"), ["run", "--quiet", "claude", "--network", "api", "--manual"])
        XCTAssertEqual(form.launch?.args, ["run", "--quiet", "claude", "--network", "api", "--no-yolo"])
        // The store asks paddock run --help once and starts with its flag.
        let a = try await make()
        XCTAssertEqual(a.h.calls(AgentArgs.runHelp).count, 1)
        XCTAssertEqual(a.agents.manualFlag, "--no-yolo")
        a.h.runner.reset(prefix: "run --help")
        try a.h.runner.on(AgentArgs.runHelp, file: Fixtures.base("run-help-manual.out"))
        await a.agents.loadChoices()
        XCTAssertEqual(a.agents.manualFlag, "--manual")
        let key = try XCTUnwrap(a.agents.start(AgentLaunch(harness: "codex", folder: "/Users/demo/x", mode: .manual)))
        XCTAssertEqual(a.processes.list.last?.command?.args.suffix(5), ["--quiet", "codex", "--network", "api", "--manual"])
        // The room of a manual run says so; ps names it once paddock has it.
        XCTAssertEqual(a.agents.room(key)?.manual, true)
        XCTAssertEqual(a.agents.room("kimi-7a8b9c")?.manual, true, "ps: approvals manual")
        XCTAssertEqual(a.agents.room("claude-1a2b3c")?.manual, false, "ps: approvals auto")
        XCTAssertEqual(a.agents.room("codex-4d5e6f")?.manual, false, "no field: full auto")
        XCTAssertEqual(AgentCopy.spoken(try XCTUnwrap(a.agents.room("kimi-7a8b9c"))),
                       "Moonshot Kimi Code in notes, Stuck, asks before each step")
        // The tag is on the run in full auto. Manual, the default, has none.
        XCTAssertEqual(AgentCopy.autoTag.english, "auto")
        XCTAssertEqual(a.agents.room(key)?.auto, false)
        XCTAssertEqual(a.agents.room("kimi-7a8b9c")?.auto, false)
        XCTAssertEqual(a.agents.room("claude-1a2b3c")?.auto, true, "ps: approvals auto")
        XCTAssertNil(a.agents.room("codex-4d5e6f")?.mode, "no field and no pane: the mode is not known")
        XCTAssertEqual(a.agents.room("codex-4d5e6f")?.auto, false)
        XCTAssertEqual(AgentCopy.spoken(try XCTUnwrap(a.agents.room("codex-4d5e6f"))), "Codex in docs, Idle")
        // A run that this launcher started in full auto has the tag too.
        let own = try XCTUnwrap(a.agents.start(AgentLaunch(harness: "gemini", folder: "/Users/demo/y", mode: .auto)))
        XCTAssertEqual(a.processes.list.last?.command?.args.suffix(5), ["run", "--quiet", "gemini", "--network", "api"])
        XCTAssertEqual(a.agents.room(own)?.auto, true)
        XCTAssertEqual(a.agents.room(own)?.manual, false)
        XCTAssertEqual(AgentCopy.spoken(try XCTUnwrap(a.agents.room(own))), "Gemini CLI in y, Starting, works on its own")
    }

    // The mode of the last start stays per agent. A user of the older
    // launcher keeps its one saved mode; a new user starts in manual.
    func testModeOfTheLastStartStaysPerAgent() throws {
        let harnesses = try HarnessJSON.list(Fixtures.data("list-agents.json"))
        XCTAssertEqual(AgentModeMemory.legacyKey, "agentMode")
        XCTAssertEqual(AgentModeMemory.key("claude"), "agentMode.claude")
        XCTAssertTrue(AgentModeMemory.isAgentKey("agentMode.claude"))
        XCTAssertFalse(AgentModeMemory.isAgentKey("agentMode"))
        XCTAssertFalse(AgentModeMemory.isAgentKey("agentMode."))
        XCTAssertFalse(AgentModeMemory.isAgentKey("agentNetwork"))

        // A new user: no key. Every agent asks before each step.
        let none: (String) -> String? = { _ in nil }
        XCTAssertEqual(AgentModeMemory.fallback(read: none), .manual)
        XCTAssertEqual(AgentModeMemory.modes(["claude", "codex"], read: none), [:])
        var fresh = AgentForm(harnesses: harnesses, recents: [], mode: AgentModeMemory.fallback(read: none),
                              modes: AgentModeMemory.modes(["claude", "codex"], read: none))
        XCTAssertEqual(fresh.harness, "claude")
        XCTAssertEqual(fresh.mode, .manual)
        fresh.choose(harness: "codex")
        XCTAssertEqual(fresh.mode, .manual)

        // A user of the older launcher who ran agents in full auto: the
        // one saved mode stays for each agent with no choice of its own.
        let older = ["agentMode": "auto", "agentMode.codex": "manual", "agentMode.gemini": "sometimes"]
        let read: (String) -> String? = { older[$0] }
        XCTAssertEqual(AgentModeMemory.fallback(read: read), .auto)
        XCTAssertEqual(AgentModeMemory.modes(["claude", "codex", "gemini"], read: read), ["codex": .manual])
        XCTAssertEqual(AgentModeMemory.fallback(read: { ["agentMode": "manual"][$0] }), .manual)
        XCTAssertEqual(AgentModeMemory.fallback(read: { ["agentMode": ""][$0] }), .manual, "no known mode: manual")
        var form = AgentForm(harnesses: harnesses, recents: [], mode: AgentModeMemory.fallback(read: read),
                             modes: AgentModeMemory.modes(harnesses.map(\.name), read: read))
        XCTAssertEqual(form.harness, "claude")
        XCTAssertEqual(form.mode, .auto, "the last choice of the older launcher")
        // The mode follows the agent, until you choose one in the form.
        form.choose(harness: "codex")
        XCTAssertEqual(form.mode, .manual, "the last start of Codex")
        form.choose(harness: "claude")
        XCTAssertEqual(form.mode, .auto)
        XCTAssertFalse(form.modeChosen)
        form.choose(mode: .manual)
        XCTAssertTrue(form.modeChosen)
        form.choose(harness: "codex")
        form.choose(harness: "claude")
        XCTAssertEqual(form.mode, .manual, "your choice in the form stays")
        // The form that opens on the agent of a room takes that agent's mode.
        let onCodex = AgentForm(harnesses: harnesses, recents: [], mode: .auto, modes: ["codex": .manual],
                                preferredHarness: "codex")
        XCTAssertEqual(onCodex.mode, .manual)
        // Full auto for one agent is no choice for the others.
        var one = AgentForm(harnesses: harnesses, recents: [], modes: ["claude": .auto])
        XCTAssertEqual(one.mode, .auto)
        one.choose(harness: "codex")
        XCTAssertEqual(one.mode, .manual)
    }

    func testSheetWithoutInstalledAgents() throws {
        let form = AgentForm(harnesses: try HarnessJSON.list(Fixtures.data("list-none-installed.json")), recents: [])
        XCTAssertEqual(form.choices.map(\.harness), ["claude", "codex"])
        XCTAssertNil(form.harness)
        XCTAssertEqual(form.missing?.english, "No agent is installed yet.")
        XCTAssertEqual(AgentForm(harnesses: [], recents: []).missing?.english, "paddock lists no agents.")
    }

    func testGitCheckAndFolderDrops() {
        let gitFolders: Set<String> = ["/Users/demo/src/shop/.git"]
        XCTAssertTrue(AgentForm.isGit("/Users/demo/src/shop", exists: gitFolders.contains))
        XCTAssertTrue(AgentForm.isGit("/Users/demo/src/shop/web/app", exists: gitFolders.contains))
        XCTAssertFalse(AgentForm.isGit("/Users/demo/Desktop", exists: gitFolders.contains))
        let folders: Set<String> = ["/Users/demo/src/shop", "/Applications/Notes.app"]
        XCTAssertEqual(AgentForm.droppedFolder(["/Users/demo/src/shop"], isFolder: folders.contains), "/Users/demo/src/shop")
        XCTAssertNil(AgentForm.droppedFolder(["/Applications/Notes.app"], isFolder: folders.contains), "an app is no project")
        XCTAssertNil(AgentForm.droppedFolder(["/Users/demo/a.txt"], isFolder: folders.contains))
    }

    // MARK: The process of a pane

    func testPaneCommandRunsPaddockThroughTheLoginShell() {
        let launch = AgentLaunch(harness: "claude", folder: "/Users/demo/src/shop", network: .api, worktree: true)
        let command = AgentCommand.paddock("/opt/homebrew/bin/paddock", args: launch.args, directory: launch.folder,
                                           environment: environment)
        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.args, ["-l", "-c", #"exec "$0" "$@""#, "/opt/homebrew/bin/paddock",
                                      "run", "--quiet", "claude", "--network", "api", "--worktree", "--no-yolo"])
        XCTAssertEqual(command.directory, "/Users/demo/src/shop")
        XCTAssertTrue(command.environment.contains("TERM=xterm-256color"))
        XCTAssertTrue(command.environment.contains("LANG=de_DE.UTF-8"), "the user's locale stays")
        XCTAssertTrue(command.environment.contains("HOME=/Users/demo"))
        // fish does not take -c with "$0": zsh runs it.
        XCTAssertEqual(AgentCommand.paddock("p", args: [], directory: nil, environment: ["SHELL": "/opt/homebrew/bin/fish"]).executable,
                       "/bin/zsh")
        XCTAssertEqual(AgentCommand.paddock("p", args: [], directory: nil, environment: ["SHELL": "/bin/bash"]).executable,
                       "/bin/bash")
    }

    func testOpenInTerminalScript() {
        let script = TerminalHandoff.script(paddock: "/opt/homebrew/bin/paddock", id: "claude-1a2b3c")
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("exec /opt/homebrew/bin/paddock view claude-1a2b3c --write\n"))
        XCTAssertTrue(script.contains(#"rm -f -- "$0""#))
        XCTAssertEqual(TerminalHandoff.fileName(id: "claude-1a2b3c"), "paddock-view-claude-1a2b3c.command")
        XCTAssertEqual(TerminalHandoff.fileName(id: "../x"), "paddock-view-x.command")
        // A path with a space is quoted for the shell.
        XCTAssertTrue(TerminalHandoff.script(paddock: "/Users/demo/my tools/paddock", id: "r").contains("exec '/Users/demo/my tools/paddock' view r --write"))
    }

    func testPaneStartFindsItsRunAndStops() async throws {
        let a = try await make()
        let launch = AgentLaunch(harness: "claude", folder: "/Users/demo/src/shop", network: .api)
        let key = try XCTUnwrap(a.agents.start(launch))
        let process = try XCTUnwrap(a.processes.list.first)
        XCTAssertEqual(process.command?.args.suffix(6), ["run", "--quiet", "claude", "--network", "api", "--no-yolo"])
        XCTAssertEqual(process.command?.directory, "/Users/demo/src/shop")
        // Before paddock lists it, the room starts.
        XCTAssertEqual(a.agents.room(key)?.state, .starting)
        XCTAssertNil(a.agents.room(key)?.runID)

        // paddock lists the new run: the pane takes it, the key stays.
        a.h.runner.reset(prefix: "ps --json")
        a.h.runner.on(["ps", "--json"], json: #"{"api_version":"paddock.ps/v1","sandboxes":[{"id":"claude-9z9z9z","harness":"claude","project":"/Users/demo/src/shop","started":"2026-11-06T10:00:02Z"},{"id":"claude-1a2b3c","harness":"claude","project":"/Users/demo/src/shop","started":1793958000}],"ended":[]}"#)
        await a.agents.refreshRuns(force: true)
        let room = try XCTUnwrap(a.agents.room(key))
        XCTAssertEqual(room.runID, "claude-9z9z9z", "the older run of the same folder is not this pane's")
        XCTAssertEqual(room.state, .working)
        XCTAssertTrue(room.paneRunning)
        XCTAssertEqual(a.agents.rooms.filter { $0.runID == "claude-9z9z9z" }.count, 1, "one room per run")

        // Stop: paddock stop with the run id.
        let failure = await a.agents.stop(room)
        XCTAssertNil(failure)
        XCTAssertEqual(a.h.calls(["stop"]).last?.args, ["stop", "claude-9z9z9z"])
        XCTAssertEqual(process.terminations, 0)
        // The process ends; the run is gone from ps: the room ended.
        a.h.runner.reset(prefix: "ps --json")
        a.h.runner.on(["ps", "--json"], json: #"{"api_version":"paddock.ps/v1","sandboxes":[],"ended":[{"id":"claude-9z9z9z","harness":"claude","project":"/Users/demo/src/shop","exit_code":0}]}"#)
        process.exit(0)
        await a.agents.refreshRuns(force: true)
        XCTAssertEqual(a.agents.room(key)?.state, .ended(done: false))
        XCTAssertFalse(a.agents.room(key)?.canStop ?? true)
        var closed: [String] = []
        a.agents.paneClosed = { closed.append($0) }
        a.agents.close(key)
        XCTAssertNil(a.agents.panes.first { $0.id == key })
        XCTAssertEqual(closed, [key], "the app drops the terminal view of a closed pane")
    }

    func testStopOfAPaneBeforeItsRunShowsEndsTheProcess() async throws {
        let a = try await make()
        let key = try XCTUnwrap(a.agents.start(AgentLaunch(harness: "codex", folder: "/Users/demo/new")))
        let process = try XCTUnwrap(a.processes.list.first)
        let room = try XCTUnwrap(a.agents.room(key))
        await a.agents.stop(room)
        XCTAssertEqual(process.terminations, 1)
        XCTAssertTrue(a.h.calls(["stop"]).isEmpty)
        // It stays: after the grace time the launcher ends it again.
        await waitUntil { a.h.clock.sleeperCount > 0 }
        a.h.clock.advance(a.agents.killAfter)
        await waitUntil { process.terminations == 2 }
        // Stopped by you: it ended, it did not fail, whatever SIGTERM gave.
        process.exit(143)
        XCTAssertEqual(a.agents.room(key)?.state, .ended(done: false))
        // A pane that ends by itself with an error failed.
        let other = try XCTUnwrap(a.agents.start(AgentLaunch(harness: "gemini", folder: "/Users/demo/new")))
        a.processes.list.last?.exit(1)
        XCTAssertEqual(a.agents.room(other)?.state, .failed(nil))
    }

    func testReopenViewsTheRunInAPane() async throws {
        let a = try await make()
        let room = try XCTUnwrap(a.agents.room("codex-4d5e6f"))
        let key = try XCTUnwrap(a.agents.reopen(room))
        let process = try XCTUnwrap(a.processes.list.first)
        XCTAssertEqual(process.command?.args.suffix(3), ["view", "codex-4d5e6f", "--write"])
        XCTAssertNil(process.command?.directory)
        // The room of the run now has the pane.
        XCTAssertEqual(a.agents.room(key)?.runID, "codex-4d5e6f")
        XCTAssertNil(a.agents.room("codex-4d5e6f"), "the room keeps one key: the pane's")
    }

    func testStreamEventsReadTheRunsAgain() async throws {
        let a = try await make()
        let before = a.h.calls(AgentArgs.ps).count
        a.agents.apply(.stream(state: "lost"))
        await waitUntil { a.h.calls(AgentArgs.ps).count > before }
        // Other events do not.
        let after = a.h.calls(AgentArgs.ps).count
        a.agents.apply(.disk(freeBytes: 1))
        await settle()
        XCTAssertEqual(a.h.calls(AgentArgs.ps).count, after)
    }

    func testPollingReadsApprovalsOnlyWhileARunLives() async throws {
        let quiet = try await make("agents-none")
        let approvals = quiet.h.calls(PaddockArgs.approvals).count
        await quiet.agents.tick()
        XCTAssertEqual(quiet.h.calls(PaddockArgs.approvals).count, approvals)
        let live = try await make()
        live.h.clock.advance(StatusGate.interval)
        let before = live.h.calls(PaddockArgs.approvals).count
        await live.agents.tick()
        XCTAssertEqual(live.h.calls(PaddockArgs.approvals).count, before + 1)
    }

    // MARK: Request cards and their answers

    func testRequestCardTexts() throws {
        let approvals = try Fixtures.decode(ApprovalsJSON.self, "approvals-agents.json")
        let exec = approvals.requests[0]
        let push = approvals.requests[1]
        XCTAssertEqual(AgentRequestCopy.pill.english, "Approval needed")
        XCTAssertEqual(AgentRequestCopy.question(exec).english, "Claude Code wants to run a command on your Mac")
        XCTAssertEqual(AgentRequestCopy.question(push).english, "Claude Code wants to push to a git remote")
        XCTAssertEqual(AgentRequestCopy.command(exec), "npm publish --dry-run")
        XCTAssertEqual(AgentRequestCopy.answers(exec), [.deny, .once, .session])
        XCTAssertEqual(AgentRequestCopy.answers(push), [.deny, .once], "no session answer where paddock has none")
        XCTAssertEqual(AgentAnswer.allCases.map(\.title.english), ["No", "Yes once", "Yes for this session"])
        XCTAssertNil(AgentRequestCopy.timeLeft(push, now: Date()))
        XCTAssertNil(AgentRequestCopy.fraction(push, now: Date()))
        // Time left and the time bar.
        let card = AgentRequestJSON(id: "r", sandbox: "s", capability: "exec",
                                    created: Date(timeIntervalSince1970: 1000), expires: Date(timeIntervalSince1970: 1120))
        XCTAssertEqual(AgentRequestCopy.timeLeft(card, now: Date(timeIntervalSince1970: 1015))?.english, "1:45 left")
        XCTAssertEqual(AgentRequestCopy.fraction(card, now: Date(timeIntervalSince1970: 1060)) ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(AgentRequestCopy.timeLeft(card, now: Date(timeIntervalSince1970: 1200))?.english, "Timed out")
        XCTAssertEqual(AgentRequestCopy.fraction(card, now: Date(timeIntervalSince1970: 1200)), 0)
        XCTAssertEqual(AgentRequestCopy.spoken(card, now: Date(timeIntervalSince1970: 1015)),
                       "Approval needed, An agent wants to run a command on your Mac, 1:45 left")
        // A capability the launcher does not know shows paddock's line.
        let other = AgentRequestJSON(id: "r", sandbox: "s", harness: "codex", capability: "kv-write", summary: "write kv key x")
        XCTAssertEqual(AgentRequestCopy.question(other).english, "Codex asks: write kv key x")
    }

    /// A request to open a web page says the host in a sentence; the full
    /// address is apart, for a disclosure, and there is no code box.
    func testARequestToOpenAPageShowsItsHost() {
        let url = "https://accounts.google.com/o/oauth2/auth?client_id=1&redirect_uri=http%3A%2F%2Flocalhost&scope=openid"
        let open = AgentRequestJSON(id: "u", sandbox: "s", harness: "agy", capability: "open-url",
                                    summary: "open a URL", detail: "Open in the host browser: " + url)
        XCTAssertEqual(AgentRequestCopy.host(open), "accounts.google.com")
        XCTAssertEqual(AgentRequestCopy.link(open), url)
        XCTAssertNil(AgentRequestCopy.command(open), "no code box with a scroll bar")
        let who = AgentCharacter.title("agy")
        XCTAssertEqual(AgentRequestCopy.question(open).english, who + " wants to open accounts.google.com in your browser")
        XCTAssertFalse(AgentRequestCopy.spoken(open, now: Date()).contains("oauth2"), "the spoken line has no long address")
        // The address alone, or in quotes, or with a full stop after it.
        let plain = AgentRequestJSON(id: "u", sandbox: "s", capability: "open-url", detail: "HTTP://Example.org/a.")
        XCTAssertEqual(AgentRequestCopy.link(plain), "HTTP://Example.org/a")
        XCTAssertEqual(AgentRequestCopy.host(plain), "example.org")
        XCTAssertEqual(AgentRequestCopy.question(plain).english, "An agent wants to open example.org in your browser")
        let quoted = AgentRequestJSON(id: "u", sandbox: "s", capability: "open-url", summary: "open \"https://x.dev/p?q=1\" now")
        XCTAssertEqual(AgentRequestCopy.link(quoted), "https://x.dev/p?q=1")
        // No address: the old sentence, and paddock's text in the box.
        let none = AgentRequestJSON(id: "u", sandbox: "s", capability: "open-url", detail: "a local file")
        XCTAssertNil(AgentRequestCopy.link(none))
        XCTAssertEqual(AgentRequestCopy.question(none).english, "An agent wants to open a web page")
        XCTAssertEqual(AgentRequestCopy.command(none), "a local file")
        // An address in a command is part of the command.
        let exec = AgentRequestJSON(id: "e", sandbox: "s", capability: "exec", detail: "curl https://example.org")
        XCTAssertNil(AgentRequestCopy.link(exec))
        XCTAssertEqual(AgentRequestCopy.command(exec), "curl https://example.org")
    }

    /// A fixture with @NOW tokens gives times relative to the clock, as
    /// the fake script does: its requests never grow old.
    func testFixtureTimesAreRelativeToTheClock() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let text = #"{"a":@NOW@,"b":@NOW-120@,"c":@NOW+600@,"d":"x@NOWy","e":"@NOW-z@"}"#
        let out = String(decoding: ReplayRunner.relativeTimes(Data(text.utf8), now: now), as: UTF8.self)
        XCTAssertEqual(out, #"{"a":2000000,"b":1999880,"c":2000600,"d":"x@NOWy","e":"@NOW-z@"}"#)
        let live = try PaddockJSON.decoder.decode(ApprovalsJSON.self, from: ReplayRunner.relativeTimes(Fixtures.data("approvals-agents-live.json"), now: now))
        XCTAssertEqual(live.requests.map(\.id), ["r-1793959080-aa11bb22", "r-1793959140-cc33dd44"])
        XCTAssertEqual(live.requests[0].created, now.addingTimeInterval(-120))
        XCTAssertTrue(live.requests.allSatisfy { !RequestAge.isExpired($0, now: now) })
        // The two requests of 6 Nov 2026 are old a week later.
        let later = Date(timeIntervalSince1970: 1_794_600_000)
        let mixed = try PaddockJSON.decoder.decode(ApprovalsJSON.self, from: ReplayRunner.relativeTimes(Fixtures.data("approvals-requests-expired.json"),
                                                                        now: later))
        let expired = mixed.requests.filter { RequestAge.isExpired($0, now: later) }.map(\.id)
        XCTAssertEqual(expired, ["r-1793959080-aa11bb22", "r-1793959140-cc33dd44", "r-timed-out-agy"])
        XCTAssertEqual(mixed.requests.first { $0.id == "r-live-url-agy" }.flatMap(AgentRequestCopy.host), "accounts.google.com")
    }

    /// An expired card is read-only: no answer, the pill says Expired.
    func testAnExpiredRequestHasNoAnswers() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let live = AgentRequestJSON(id: "a", sandbox: "s", capability: "exec", created: now.addingTimeInterval(-60),
                                    expires: now.addingTimeInterval(60), sessionAllowed: true)
        let timedOut = AgentRequestJSON(id: "b", sandbox: "s", capability: "exec", created: now.addingTimeInterval(-600),
                                        expires: now.addingTimeInterval(-1), sessionAllowed: true)
        let old = AgentRequestJSON(id: "c", sandbox: "s", capability: "push", created: now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(AgentRequestCopy.answers(live, now: now), [.deny, .once, .session])
        XCTAssertEqual(AgentRequestCopy.answers(timedOut, now: now), [])
        XCTAssertEqual(AgentRequestCopy.answers(old, now: now), [])
        XCTAssertFalse(AgentRequestCopy.isExpired(live, now: now))
        XCTAssertTrue(AgentRequestCopy.isExpired(timedOut, now: now))
        XCTAssertEqual(AgentRequestCopy.spoken(old, now: now),
                       "Expired, An agent wants to push to a git remote, This request expired. You can no longer answer it.")
        XCTAssertTrue(AgentRequestCopy.spoken(live, now: now).hasPrefix("Approval needed, "))
    }

    func testAnswersOfARequest() async throws {
        let a = try await make()
        XCTAssertEqual(a.h.store.agentRequests.count, 2)
        let exec = a.h.store.agentRequests[0]
        let push = a.h.store.agentRequests[1]
        // Yes for this session where paddock does not allow it: no call.
        let refused = await a.agents.answer(push, .session)
        XCTAssertNotNil(refused)
        XCTAssertTrue(a.h.calls(["approvals", "answer"]).isEmpty)
        // Yes once, No: the word of paddock approvals answer.
        let once = await a.agents.answer(exec, .once)
        XCTAssertNil(once)
        XCTAssertEqual(a.h.calls(["approvals", "answer"]).last?.args, ["approvals", "answer", "r-1793959080-aa11bb22", "once"])
        await a.agents.answer(push, .deny)
        XCTAssertEqual(a.h.calls(["approvals", "answer"]).last?.args, ["approvals", "answer", "r-1793959140-cc33dd44", "deny"])
        XCTAssertEqual(a.h.store.agentRequests, [])
        XCTAssertEqual(a.agents.room("claude-1a2b3c")?.state, .waiting(1), "the board still says waiting")
        // A listing read before the answers arrived does not bring them back.
        a.h.clock.advance(StatusGate.interval)
        await a.h.store.reloadApprovals()
        XCTAssertEqual(a.h.store.agentRequests, [])
        // The app question of the same listing is untouched.
        XCTAssertEqual(a.h.store.questions.map(\.id), ["r-shown-g1"])
        // A failed answer keeps the card and gives paddock's line.
        let h = try await make()
        h.h.runner.reset(prefix: "approvals answer")
        h.h.runner.on(["approvals", "answer"], json: "", status: 1, stderr: "error: request r-1 timed out")
        let line = await h.agents.answer(h.h.store.agentRequests[0], .once)
        XCTAssertEqual(line, "error: request r-1 timed out")
        XCTAssertEqual(h.h.store.agentRequests.count, 2)
    }

    // MARK: Menu bar

    func testMenuBarListsRunningAgentsAndRequests() async throws {
        let a = try await make()
        let menu = MenuModel.of(a.h.store, keepRunning: true, agents: a.agents.rooms)
        XCTAssertEqual(menu.agents.map(\.key), ["claude-1a2b3c", "kimi-7a8b9c", "codex-4d5e6f"], "running only")
        XCTAssertEqual(menu.agents.map(\.line.english), [
            "Claude Code in shop — Waiting for you · 2 requests",
            "Moonshot Kimi Code in notes — Stuck",
            "Codex in docs — Idle",
        ])
        XCTAssertEqual(menu.agentRequestsItem?.english, "Agent requests… (2)")
        XCTAssertEqual(menu.iconState, .question)
        // Without agents the menu is as before.
        let none = try await make("agents-none")
        let plain = MenuModel.of(none.h.store, keepRunning: true, agents: none.agents.rooms)
        XCTAssertEqual(plain.agents, [])
        XCTAssertNil(plain.agentRequestsItem)
    }

    // MARK: Notifications

    func testNotificationsWhenAnAgentWaitsOrEnds() throws {
        let start = ISO.date("2026-11-06T10:00:00Z")
        let request = AgentRequestJSON(id: "r1", sandbox: "run-1", harness: "claude", capability: "exec",
                                       detail: "make deploy", created: start)
        var room = AgentRoom(key: "run-1", runID: "run-1", paneID: nil, harness: "claude", title: "Claude Code",
                             project: "/Users/demo/src/shop", branch: nil, started: start, ended: nil, state: .working,
                             requests: [], filesChanged: nil, files: nil, activity: nil, network: nil, paneRunning: false)
        var notifier = AgentNotifier()
        XCTAssertEqual(notifier.update([room], now: start, threshold: 30), [])
        // A request notifies after the threshold of the question setting.
        room.state = .waiting(1)
        room.requests = [request]
        XCTAssertEqual(notifier.update([room], now: start.addingTimeInterval(10), threshold: 30), [])
        let waiting = notifier.update([room], now: start.addingTimeInterval(31), threshold: 30)
        XCTAssertEqual(waiting.map(\.id), ["agent-request-r1"])
        XCTAssertEqual(waiting.first?.title.english, "Claude Code in shop is waiting for you")
        XCTAssertEqual(waiting.first?.body.english, "Claude Code wants to run a command on your Mac")
        XCTAssertEqual(waiting.first?.kind, .waiting)
        XCTAssertEqual(notifier.update([room], now: start.addingTimeInterval(60), threshold: 30), [], "once")
        // The end notifies at once, once.
        room.state = .ended(done: true)
        room.requests = []
        let ended = notifier.update([room], now: start.addingTimeInterval(90), threshold: 30)
        XCTAssertEqual(ended.map(\.title.english), ["Claude Code in shop ended"])
        XCTAssertEqual(notifier.update([room], now: start.addingTimeInterval(91), threshold: 30), [])
        // A failure says so.
        var failed = room
        failed.key = "run-2"
        failed.runID = "run-2"
        failed.state = .working
        _ = notifier.update([failed], now: start, threshold: 30)
        failed.state = .failed("no API key")
        let failure = notifier.update([failed], now: start, threshold: 30)
        XCTAssertEqual(failure.map(\.title.english), ["Claude Code in shop failed"])
        XCTAssertEqual(failure.first?.body.english, "Failed · no API key")
        // A run that had ended before the launcher saw it: no notification.
        var old = room
        old.key = "run-old"
        old.runID = "run-old"
        var fresh = AgentNotifier()
        XCTAssertEqual(fresh.update([old], now: start, threshold: 30), [])
        // "Never" turns both off.
        var never = AgentNotifier()
        var live = room
        live.state = .waiting(1)
        live.requests = [request]
        XCTAssertEqual(never.update([live], now: start.addingTimeInterval(600), threshold: nil), [])
        live.state = .ended(done: false)
        XCTAssertEqual(never.update([live], now: start.addingTimeInterval(601), threshold: nil), [])
    }

    // MARK: The launcher protocol

    /// paddock's `--launcher-protocol` names no agent feature yet, so the
    /// expected list stays as it was.
    func testTheProtocolGateIsUnchanged() {
        XCTAssertEqual(LauncherProtocol.required, ["app-list-v1", "approvals-v1", "events-v1", "macvm-status-v1",
                                                   "setup-progress-v1"])
    }
}
