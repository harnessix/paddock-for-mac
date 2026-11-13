import AppKit
import PaddockKit
import XCTest
@testable import PaddockLauncher

/// The terminal pane of an agent, with the fake paddock in a real SwiftTerm
/// pseudo terminal: Start runs `paddock run AGENT --network N` in the
/// folder through the login shell, the pane shows what it prints, Stop
/// ends it and the room ends. Also: Open in Terminal, the Dock folder
/// type and the texts of the agent screens.
@MainActor
final class AgentPaneChecks: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AppTests
        .deletingLastPathComponent() // launcher

    static var fake: String { root.appendingPathComponent("FakePaddock/fake-paddock").path }

    var state: URL!
    var folder: URL!

    override func setUp() async throws {
        state = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-pane-" + UUID().uuidString)
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-project-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: state)
        try? FileManager.default.removeItem(at: folder)
    }

    /// The fake paddock's environment: the agents scenario and a scratch
    /// folder for its call log.
    var fakeEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PADDOCK_FAKE_SCENARIO"] = AgentPaneChecks.root.appendingPathComponent("Fixtures/agents").path
        env["PADDOCK_FAKE_STATE"] = state.path
        return env
    }

    /// A store checked against the fake paddock, and its agent store with
    /// real panes.
    func makeStores() async -> (LauncherStore, AgentStore) {
        for (key, value) in fakeEnvironment where key.hasPrefix("PADDOCK_FAKE") { setenv(key, value, 1) }
        let store = LauncherStore(service: nil)
        let fake = AgentPaneChecks.fake
        await store.start(locate: { fake }, makeService: { CLIPaddockService(runner: ProcessRunner(executable: $0)) })
        XCTAssertTrue(store.binary.isUsable, "\(store.binary)")
        let agents = AgentStore(launcher: store, environment: fakeEnvironment, paddockPath: { fake },
                                makeProcess: { TerminalPanes.shared.process(for: $0) })
        await agents.loadChoices()
        return (store, agents)
    }

    var calls: [String] {
        let text = (try? String(contentsOf: state.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { line in
            line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        }
    }

    /// Waits for a condition and gives the main queue back while it waits.
    /// The checks run as a job of the main queue (the class is on the main
    /// actor), and a nested `RunLoop.run` does not drain that queue again:
    /// SwiftTerm's output (`DispatchQueue.main.sync`) and its exit event
    /// would never come. `Task.sleep` ends the job, so the queue runs.
    func wait(_ what: String, timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let met = condition()
        XCTAssertTrue(met, what)
    }

    func testPaneStartsPaddockRunInTheFolderAndStops() async throws {
        let (store, agents) = await makeStores()
        defer { store.stopEvents() }
        let launch = AgentLaunch(harness: "claude", folder: folder.path, network: .api, worktree: true)
        let key = try XCTUnwrap(agents.start(launch))
        let terminal = try XCTUnwrap(TerminalPanes.shared.terminal(key))
        XCTAssertTrue(terminal.running)
        // paddock got the run, with the options of the sheet.
        await wait("paddock run was called: \(calls)") { self.calls.contains("run --quiet claude --network api --worktree --no-yolo") }
        // The pane shows what paddock prints.
        await wait("the pane shows the agent: \(terminal.screenText)") { terminal.screenText.contains("Claude Code is ready.") }
        XCTAssertEqual(agents.room(key)?.state, .starting)
        // The fake lists no run of this pane, so Stop ends the process.
        let room = try XCTUnwrap(agents.room(key))
        let failure = await agents.stop(room)
        XCTAssertNil(failure)
        await wait("the process ended") { !terminal.running }
        XCTAssertEqual(agents.room(key)?.state, .ended(done: false), "a stop you asked for is no failure")
        XCTAssertFalse(agents.room(key)?.canStop ?? true)
        XCTAssertFalse(calls.contains { $0.hasPrefix("stop") }, "no run id: no paddock stop")
        agents.close(key)
        TerminalPanes.shared.remove(key)
        XCTAssertNil(TerminalPanes.shared.terminal(key))
    }

    func testReopenRunsPaddockViewWrite() async throws {
        let (store, agents) = await makeStores()
        defer { store.stopEvents() }
        await agents.refreshRuns(force: true)
        let room = try XCTUnwrap(agents.room("codex-4d5e6f"))
        let key = try XCTUnwrap(agents.reopen(room))
        let terminal = try XCTUnwrap(TerminalPanes.shared.terminal(key))
        await wait("paddock view was called: \(calls)") { self.calls.contains("view codex-4d5e6f --write") }
        await wait("the pane shows the view") { terminal.screenText.contains("view of claude-1a2b3c") }
        // A run that paddock lists stops with paddock stop.
        let failure = await agents.stop(try XCTUnwrap(agents.room(key)))
        XCTAssertNil(failure)
        await wait("paddock stop was called") { self.calls.contains("stop codex-4d5e6f") }
        terminal.terminate()
        await wait("the view ended") { !terminal.running }
        agents.close(key)
        TerminalPanes.shared.remove(key)
    }

    func testExitStatusOfWaitpid() {
        XCTAssertEqual(PaneTerminal.exitStatus(0), 0)
        XCTAssertEqual(PaneTerminal.exitStatus(1 << 8), 1)
        XCTAssertEqual(PaneTerminal.exitStatus(SIGTERM), 128 + SIGTERM)
        XCTAssertEqual(PaneTerminal.exitStatus(SIGKILL), 137)
    }

    func testOpenInTerminalWritesAViewCommand() throws {
        let script = TerminalHandoff.script(paddock: AgentPaneChecks.fake, id: "claude-1a2b3c")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("check-" + UUID().uuidString + ".command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        // The file is a shell script that sh can read.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // A project folder dropped on the Dock icon reaches the launcher, which
    // never becomes the opener of folders.
    func testDockAcceptsFoldersAsAlternate() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let folders = try XCTUnwrap(types.first { ($0["LSItemContentTypes"] as? [String])?.contains("public.folder") == true })
        XCTAssertEqual(folders["LSHandlerRank"] as? String, "Alternate")
        XCTAssertEqual(folders["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertTrue(NewAgentSheet.isFolder(folder.path))
        XCTAssertTrue(NewAgentSheet.isGit(folder.path))
        XCTAssertFalse(NewAgentSheet.isGit(NSTemporaryDirectory()))
    }

    func testAgentTextsResolve() {
        XCTAssertEqual(AgentState.waiting(2).line.localized, "Waiting for you · 2 requests")
        XCTAssertEqual(AgentRequestCopy.pill.localized, "Approval needed")
        XCTAssertEqual(AgentAnswer.session.title.localized, "Yes for this session")
        XCTAssertEqual(AgentNetwork.api.title.localized, "Only its AI service")
        XCTAssertEqual(AgentGap.board.line.localized, "Needs a paddock with paddock board --json")
        XCTAssertEqual(AgentQuitCopy.question(2).localized, "Quit and stop 2 agents?")
        // The snapshot switch knows the agents.
        XCTAssertEqual(SnapshotDump.sidebarItem(for: "Agents", apps: []), .agents)
        XCTAssertEqual(SnapshotDump.sidebarItem(for: "agent:claude-1a2b3c", apps: []), .agent("claude-1a2b3c"))
    }

    // Every agent text has a value in every language.
    func testAgentKeysHaveEveryLanguage() throws {
        let catalogURL = AgentPaneChecks.root.appendingPathComponent("App/Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for key in ["Agents", "New Agent…", "Approval needed", "Yes once", "Yes for this session", "No",
                    "Waiting for you", "Work in a new branch", "Open in Terminal", "Needs a paddock with %@",
                    AgentMode.manual.title.key, AgentMode.auto.title.key, AgentMode.manual.detail.key,
                    AgentMode.auto.detail.key, AgentCopy.autoTag.key, "Works on its own", "works on its own",
                    "Asks before each step", "asks before each step"] {
            for language in InterfaceLanguages.all {
                XCTAssertFalse(InterfaceLanguages.texts(strings[key], language).isEmpty, "\(language): \(key)")
            }
        }
    }
}
