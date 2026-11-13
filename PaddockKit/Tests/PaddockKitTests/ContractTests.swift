import XCTest
@testable import PaddockKit

/// The contract with the real paddock: every file of Fixtures/real-0.2.2 is
/// the output of paddock 0.2.2 on a Mac (URLs, emails and IDs replaced).
/// Each one goes through the code path that the launcher uses for its
/// command, with the exit status paddock gave, and the decoded values must
/// be the ones in the file.
@MainActor
final class ContractTests: XCTestCase {
    static let folder = Fixtures.root.appendingPathComponent("real-0.2.2")

    func real(_ name: String) throws -> Data {
        try Data(contentsOf: ContractTests.folder.appendingPathComponent(name))
    }

    /// A service whose paddock answers `args` with the file and `status`.
    func service(_ args: [String], _ name: String, status: Int32 = 0) throws -> (CLIPaddockService, ReplayRunner) {
        let runner = ReplayRunner(clock: FakeClock())
        runner.on(args, output: CommandOutput(status: status, stdout: try real(name), stderr: ""))
        return (CLIPaddockService(runner: runner), runner)
    }

    /// The files this test reads. A new file in the folder must get a case.
    static let covered: Set<String> = [
        "version.out", "doctor.json", "macvm_status.json", "app_list.json", "approvals.json", "events.jsonl",
        "du.json", "gc.json", "precheck.json", "list.json", "recent.json", "ps.json", "board.json",
    ]

    func testEveryRealFileHasACase() throws {
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: ContractTests.folder.path))
        XCTAssertEqual(names, ContractTests.covered)
    }

    // MARK: --version

    func testVersion() async throws {
        let (service, _) = try service(PaddockArgs.version, "version.out")
        let text = try await service.version()
        XCTAssertEqual(VersionGate.current.check(versionOutput: text), .ok(version: "0.2.2"))
    }

    // MARK: doctor --json

    func testDoctorDecodes() async throws {
        let (service, runner) = try service(PaddockArgs.doctor, "doctor.json")
        let d = try await service.doctor()
        XCTAssertEqual(runner.calls.map(\.args), [PaddockArgs.doctor])
        XCTAssertEqual(d.v, 1)
        XCTAssertEqual(d.ok, true)
        XCTAssertEqual(d.checks.map(\.id), ["apple_silicon", "macos", "free_space", "memory", "entitlement", "slots"])
        XCTAssertEqual(Set(d.checks.map(\.level)), ["ok"])
        XCTAssertEqual(d.checks[0].text, "This Mac has Apple silicon (Apple M4).")
        XCTAssertEqual(d.checks[2].text, "66.5 GiB free, 44 GiB needed.")
        XCTAssertEqual(d.chip, DoctorChipJSON(appleSilicon: true, name: "Apple M4"))
        XCTAssertEqual(d.disk, DoctorDiskJSON(dir: "/Users/demo/.local/share/paddock/macvm", free: 71_353_364_480,
                                              need: 47_212_254_720, ok: true))
        XCTAssertEqual(d.macos, DoctorMacOSJSON(version: "27.2", minMajor: 14, ok: true))
        XCTAssertEqual(d.memory, DoctorMemoryJSON(bytes: 17_179_869_184, defaultMib: 4096, perAppMaxMib: 8192))
        XCTAssertEqual(d.entitlement?.present, true)
        XCTAssertEqual(d.entitlement?.helper, "/opt/homebrew/bin/paddock-vm")
        XCTAssertEqual(d.golden?.state, "missing")
        XCTAssertEqual(d.slots?.total, 2)
        XCTAssertEqual(d.slots?.used, 0)
        XCTAssertEqual(d.slots?.holders, [nil, nil])
        XCTAssertEqual(d.paddock?.version, "0.2.2")
    }

    /// The checklist of the real report: one row per check, paddock's line
    /// verbatim, all passed, Continue on.
    func testDoctorChecklist() async throws {
        let (service, _) = try service(PaddockArgs.doctor, "doctor.json")
        let phase = await DoctorPhase.run(service)
        let rows = Prerequisites.rows(phase: phase, binary: .ok(version: "0.2.2"), binaryMissing: false)
        XCTAssertEqual(rows.map(\.kind), [.chip, .macos, .paddock, .space, .memory, .entitlement, .slots])
        XCTAssertEqual(rows.map(\.status), Array(repeating: .pass, count: 7))
        XCTAssertEqual(rows.map(\.result.english), [
            "This Mac has Apple silicon (Apple M4).", "macOS 27.2.", "paddock 0.2.2 found",
            "66.5 GiB free, 44 GiB needed.", "16 GiB: each app gets up to 8 GiB.",
            "paddock-vm has the Virtualization entitlement.", "0 of 2 macOS VMs run.",
        ])
        XCTAssertTrue(rows.allSatisfy { $0.actions.isEmpty })
        XCTAssertTrue(Prerequisites.canContinue(rows))
    }

    /// paddock exits 1 when a check fails and prints the whole report: the
    /// report wins over the exit status.
    func testDoctorReportWithExitOne() async throws {
        let (service, _) = try service(PaddockArgs.doctor, "doctor.json", status: 1)
        guard case .report(let d) = await DoctorPhase.run(service) else { return XCTFail("no report") }
        XCTAssertEqual(d.checks.count, 6)
    }

    // MARK: macvm status --json

    func testMacvmStatus() async throws {
        let (service, _) = try service(PaddockArgs.macvmStatus, "macvm_status.json")
        let status = try await service.macvmStatus()
        XCTAssertEqual(status.v, 1)
        XCTAssertEqual(status.golden.state, "none")
        XCTAssertEqual(status.golden.dir, "/Users/demo/.local/share/paddock/macvm")
        XCTAssertEqual(status.golden.hostVersion, "27.2")
        XCTAssertEqual(status.golden.appsUsing, 0)
        XCTAssertNil(status.golden.setup)
        let store = LauncherStore(service: service, clock: FakeClock())
        store.applyStatus(status)
        XCTAssertEqual(store.golden, .none)
        XCTAssertTrue(store.goldenLoaded)
    }

    // MARK: app list --json

    func testAppList() async throws {
        let (service, _) = try service(PaddockArgs.appList, "app_list.json")
        let apps = try await service.listApps()
        XCTAssertEqual(apps.map(\.name), ["chatgpt-desktop", "claude-desktop", "vscode"])
        XCTAssertEqual(apps.map(\.displayName), ["ChatGPT", "Claude", "Code"])
        XCTAssertEqual(apps.map(\.version), ["26.1029.61003", "3.6556.1", "1.143.1"])
        XCTAssertEqual(apps.map(\.bundlePath), ["/Applications/ChatGPT.app", "/Applications/Claude.app",
                                                "/Applications/Visual Studio Code.app"])
        XCTAssertEqual(Set(apps.map(\.state)), ["stopped"])
        XCTAssertEqual(Set(apps.map(\.home)), ["default"])
        XCTAssertEqual(apps[0].nextStart, "Cold, about 40 s: the first start of this profile")
        XCTAssertEqual(apps[0].launcher, false)
        XCTAssertEqual(apps[0].bytes, 0)
        XCTAssertNil(apps[0].blockCode)
        XCTAssertNil(apps[0].network, "an empty mode is no mode")
        XCTAssertEqual(apps[0].sizes, AppSizesJSON(appCopy: 0, data: 0, savedState: 0))
        XCTAssertEqual(apps[0].hostDiskFree, 71_353_348_096)
        XCTAssertEqual(apps.map(\.id), ["chatgpt-desktop", "claude-desktop", "vscode"])
        // The library shows them, and the free space comes from the list:
        // paddock 0.2.2 `macvm status` has no disk.
        let store = LauncherStore(service: service, clock: FakeClock())
        store.applyList(apps)
        XCTAssertEqual(store.apps.map(\.key), ["chatgpt-desktop", "claude-desktop", "vscode"])
        XCTAssertEqual(store.apps.map(\.json.displayName), ["ChatGPT", "Claude", "Code"])
        XCTAssertEqual(store.disk?.freeBytes, 71_353_348_096)
    }

    // MARK: approvals --json

    func testApprovals() async throws {
        let (service, _) = try service(PaddockArgs.approvals, "approvals.json")
        let approvals = try await service.approvals()
        XCTAssertEqual(approvals.v, 1)
        XCTAssertTrue(approvals.complete)
        XCTAssertEqual(approvals.diagnostics, [])
        // Two `open-url` requests of agent sandboxes: no app question.
        XCTAssertEqual(approvals.questions, [])
        XCTAssertNil(approvals.paused)
    }

    // MARK: events --follow --json

    func testEvents() throws {
        let lines = try ReplayRunner.streamLines(ContractTests.folder.appendingPathComponent("events.jsonl"))
        XCTAssertEqual(lines.map { PaddockEvent.decode(line: $0) }, [.stream(state: "started")])
    }

    // MARK: du --json

    /// The Storage pane decodes `du` with `PaddockJSON.decoder`. paddock
    /// 0.2.2 printed no `macvm` part on a Mac without a base image: the
    /// pane shows its empty state.
    func testDu() throws {
        let du = try PaddockJSON.decoder.decode(DuReportJSON.self, from: real("du.json"))
        XCTAssertEqual(du.apiVersion, "paddock.du/v1")
        XCTAssertEqual(du.anyRunning, false)
        XCTAssertNil(du.macvm)
        XCTAssertNil(StorageReport.of(du, apps: [], freeBytes: 71_353_348_096))
    }

    // MARK: gc --json

    func testGc() throws {
        let gc = try PaddockJSON.decoder.decode(GcReportJSON.self, from: real("gc.json"))
        XCTAssertEqual(gc.apiVersion, "paddock.gc/v1")
        XCTAssertEqual(gc.dryRun, true)
        XCTAssertEqual(gc.items.count, 14)
        XCTAssertEqual(gc.notes, ["docker: cannot list images (is the daemon running?)"])
        XCTAssertEqual(gc.removed?.count, 0)
        let first = gc.items[0]
        XCTAssertEqual(first.what, "home agy/isolated-check/paddock-real_HsYe-dec0931e40")
        XCTAssertEqual(first.tier, "consent")
        XCTAssertEqual(first.bytes, 40_099_840)
        XCTAssertEqual(first.needs, ["--homes"])
        XCTAssertEqual(first.reason, "the project /private/tmp/paddock-real.HsYe is gone")
        XCTAssertEqual(first.action?.kind, "path")
        XCTAssertEqual(first.action?.target,
                       "/Users/demo/.local/share/paddock/homes/agy/isolated-check/paddock-real_HsYe-dec0931e40")
        let caches = gc.items[11]
        XCTAssertEqual(caches.action?.kind, "caches")
        XCTAssertEqual(caches.action?.folders, [".codex/cache"])
        XCTAssertEqual(caches.action?.home, "/Users/demo/.local/share/paddock/homes/codex/isolated-check/proj-1f8c90eae3")
        XCTAssertNil(caches.warning)

        // Without the option: the five `auto` items. With it: the homes too,
        // which need `--homes` only.
        let plain = CleanupPreview.of(gc, includeLogins: false)
        XCTAssertEqual(plain.removedNow.count, 5)
        XCTAssertEqual(plain.bytesNow, 5_050_368)
        XCTAssertEqual(plain.kept.count, 9)
        XCTAssertTrue(plain.hasOtherData)
        XCTAssertEqual(Set(plain.items.map(\.id)).count, 14, "each item has its own id")
        let all = CleanupPreview.of(gc, includeLogins: true)
        XCTAssertEqual(all.removedNow.count, 14)
    }

    // MARK: app add PATH --dry-run --json

    /// The precheck of a Mac without a base image: paddock exits 1 with the
    /// whole report. The sheet shows each check, the failed one with
    /// paddock's line and Build, and offers Check Again.
    func testPrecheckReview() async throws {
        let path = "/System/Applications/Calculator.app"
        let (service, runner) = try service(LibraryArgs.review(path), "precheck.json", status: 1)
        let store = LauncherStore(service: service, clock: FakeClock())
        store.binary = .found(path: "/fake/paddock", verdict: .ok(version: "0.2.2"))
        let review = await store.review(path: path)
        XCTAssertEqual(runner.calls.map(\.args), [LibraryArgs.review(path)])
        XCTAssertNil(review.failure)
        XCTAssertNil(review.existing)
        XCTAssertEqual(review.name, "calculator")
        XCTAssertEqual(review.displayName, "Calculator")
        XCTAssertEqual(review.version, "12.0")
        XCTAssertEqual(review.bytes, 4_955_350)
        XCTAssertEqual(review.checks.map(\.kind), [.bundle, .appStore, .golden, .space])
        XCTAssertEqual(review.checks.map(\.status), [.pass, .pass, .fail, .pass])
        XCTAssertEqual(review.checks[0].detail.english, "Version 12.0")
        XCTAssertEqual(review.checks[3].detail.english, "71.4 GB free, 8.6 GB needed")
        XCTAssertEqual(review.firstFailure?.kind, .golden)
        XCTAssertEqual(review.firstFailure?.detail.english, "Build the base image first: paddock macvm setup.")
        XCTAssertEqual(review.firstFailure?.action, .build)
        XCTAssertFalse(review.canAdd)
        XCTAssertTrue(review.canCheckAgain)
        XCTAssertEqual(review.memoryOptions, [4, 6, 8])
        XCTAssertEqual(review.defaultMemory, 4)
    }

    /// The same file through the older precheck call of the add flow.
    func testPrecheckVerdict() async throws {
        let path = "/System/Applications/Calculator.app"
        let (service, _) = try service(PaddockArgs.precheck(path), "precheck.json", status: 1)
        let precheck = try await service.precheck(path)
        XCTAssertFalse(precheck.ok)
        XCTAssertEqual(precheck.name, "calculator")
        XCTAssertEqual(precheck.golden, "none")
        XCTAssertEqual(precheck.needBytes, 8_594_889_942)
        XCTAssertEqual(precheck.freeBytes, 71_353_253_888)
        XCTAssertEqual(precheck.message, "Build the base image first: paddock macvm setup.")
        XCTAssertEqual(AddVerdict.of(precheck), .noGolden)
    }

    /// A precheck that hangs is killed at 20 s: the sheet shows that line
    /// and Check Again, not "Checking the app…" for ever.
    func testPrecheckTimeLimit() async throws {
        let path = "/System/Applications/Calculator.app"
        let clock = FakeClock()
        let runner = ReplayRunner(clock: clock)
        runner.hang(prefix: LibraryArgs.review(path).joined(separator: " "))
        let store = LauncherStore(service: CLIPaddockService(runner: runner), clock: clock)
        store.binary = .found(path: "/fake/paddock", verdict: .ok(version: "0.2.2"))
        let task = Task { await store.review(path: path) }
        await waitUntil { runner.hanging == 1 && clock.sleeperCount == 1 }
        clock.advance(DoctorPhase.limits.seconds)
        let review = await task.value
        XCTAssertEqual(review.failure, "paddock did not answer in 20 seconds.")
        XCTAssertFalse(review.canAdd)
        XCTAssertTrue(review.canCheckAgain)
        XCTAssertEqual(runner.kills, 1)
    }

    // MARK: list, recent, ps, board

    /// The agent rooms run `list`, `recent`, `ps` and `board`: an agent
    /// store whose paddock answers each of them with its real file.
    func agents() throws -> (AgentStore, ReplayRunner) {
        let clock = FakeClock()
        let runner = ReplayRunner(clock: clock)
        let files = [(AgentArgs.list, "list.json"), (AgentArgs.recent, "recent.json"), (AgentArgs.ps, "ps.json"),
                     (AgentArgs.board, "board.json")]
        for (args, name) in files {
            runner.on(args, output: CommandOutput(status: 0, stdout: try real(name), stderr: ""))
        }
        let launcher = LauncherStore(service: CLIPaddockService(runner: runner), clock: clock)
        let agents = AgentStore(launcher: launcher, environment: [:], paddockPath: { "/fake/paddock" },
                                makeProcess: { _ in FakeAgentProcess() })
        return (agents, runner)
    }

    /// The four agent commands have a case below. An argument list that
    /// starts with one of their words is in `AgentArgs` and nowhere else,
    /// so a new call of one of them goes through the lists that these
    /// cases answer.
    func testAgentCommandsHaveACase() throws {
        XCTAssertEqual(AgentArgs.list, ["list", "--json"])
        XCTAssertEqual(AgentArgs.recent, ["recent", "--json"])
        XCTAssertEqual(AgentArgs.ps, ["ps", "--json"])
        XCTAssertEqual(AgentArgs.board, ["board", "--json"])
        XCTAssertEqual(Set(AgentGap.allCases.map(\.command)),
                       ["paddock list --json", "paddock recent --json", "paddock ps --json", "paddock board --json"])

        let sources = Fixtures.root.deletingLastPathComponent().appendingPathComponent("PaddockKit/Sources")
        let call = try NSRegularExpression(pattern: #"\[\s*"(list|recent|ps|board)""#)
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        var inAgentArgs = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let found = call.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if file.lastPathComponent == "AgentLaunch.swift" {
                inAgentArgs = found
            } else {
                XCTAssertEqual(found, 0, "\(file.lastPathComponent) runs an agent command: use AgentArgs and add its contract case")
            }
        }
        XCTAssertEqual(inAgentArgs, 4, "AgentArgs has the four agent commands: a new one needs a contract case")
    }

    /// `list --json`: 28 harnesses, two installed, three desktop apps.
    func testListDecodes() async throws {
        let list = try object("list.json")
        XCTAssertEqual(list["api_version"] as? String, "paddock.list/v1")

        let (agents, runner) = try agents()
        await agents.loadChoices()
        XCTAssertEqual(runner.calls(startingWith: AgentArgs.list).count, 1)
        XCTAssertTrue(agents.harnessesLoaded)
        XCTAssertFalse(agents.gaps.contains(.list))
        XCTAssertEqual(agents.harnesses.count, 28)
        XCTAssertEqual(agents.harnesses.filter(\.installed).map(\.name), ["agy", "codex"])
        XCTAssertEqual(agents.harnesses.filter(\.app).map(\.name), ["chatgpt-desktop", "claude-desktop", "vscode"])
        XCTAssertEqual(agents.agentHarnesses.count, 25)
        let codex = try XCTUnwrap(agents.harnesses.first { $0.name == "codex" })
        XCTAssertEqual(codex, HarnessJSON(name: "codex", summary: "OpenAI Codex CLI",
                                          exe: "/opt/homebrew/Caskroom/codex/0.166.0/bin/codex", installed: true, app: false))
        // `"exe":null` of a harness that is not installed reads as no path.
        let claude = try XCTUnwrap(agents.harnesses.first { $0.name == "claude" })
        XCTAssertEqual(claude, HarnessJSON(name: "claude", summary: "Anthropic Claude Code", exe: nil,
                                           installed: false, app: false))
    }

    /// `recent --json` of a Mac with no project yet: an empty list, and
    /// not a missing command.
    func testRecentDecodes() async throws {
        let recent = try object("recent.json")
        XCTAssertEqual(recent["api_version"] as? String, "paddock.recent/v1")
        XCTAssertEqual((recent["projects"] as? [Any])?.count, 0)

        let (agents, runner) = try agents()
        await agents.loadChoices()
        XCTAssertEqual(runner.calls(startingWith: AgentArgs.recent).count, 1)
        XCTAssertEqual(agents.recents, [])
        XCTAssertFalse(agents.gaps.contains(.recent))
        XCTAssertEqual(try RecentProjectJSON.list(real("recent.json")), [])
    }

    /// The New Agent sheet builds its rows from the real list and the
    /// real recent projects, as `NewAgentSheet` does from the store.
    func testAgentSheetRows() async throws {
        let (agents, _) = try agents()
        await agents.loadChoices()
        var form = AgentForm(harnesses: agents.harnesses, recents: agents.recents)
        // The desktop apps have no tile. The six known agents come first,
        // then the others by name.
        XCTAssertEqual(form.choices.map(\.harness),
                       ["claude", "codex", "gemini", "copilot", "grok", "opencode",
                        "agy", "amp", "commandcode", "crush", "cursor-agent", "devin", "dsh", "freebuff", "hermes",
                        "kilo", "kimi", "kiro-cli", "mcode", "muse", "omp", "openclaw", "ori", "pi", "qwen"])
        XCTAssertEqual(form.choices.filter(\.installed).map(\.harness), ["codex", "agy"])
        let codex = try XCTUnwrap(form.choices.first { $0.harness == "codex" })
        XCTAssertEqual(codex.title, "Codex")
        XCTAssertEqual(codex.color, .blue)
        XCTAssertNil(codex.hint)
        XCTAssertEqual(codex.spoken.english, "Codex, installed")
        // A harness without a known name has paddock's description.
        let agy = try XCTUnwrap(form.choices.first { $0.harness == "agy" })
        XCTAssertEqual(agy.title, "Google Antigravity CLI")
        XCTAssertEqual(agy.color, .gray)
        let claude = try XCTUnwrap(form.choices.first { $0.harness == "claude" })
        XCTAssertEqual(claude.title, "Claude Code")
        XCTAssertFalse(claude.installed)
        // paddock 0.2.2 gives no install command: the launcher's own one.
        XCTAssertEqual(claude.install, "npm install -g @anthropic-ai/claude-code")
        XCTAssertEqual(claude.hint, AgentCopy.installHintCommand)
        let devin = try XCTUnwrap(form.choices.first { $0.harness == "devin" })
        XCTAssertNil(devin.install)
        XCTAssertEqual(devin.hint, AgentCopy.installHintManual, "no command known: install it by hand")
        // No recent project: no folder row, and the first installed agent
        // is the choice. A tile of an agent that is not installed does
        // not take the choice.
        XCTAssertEqual(form.folders, [])
        XCTAssertEqual(form.harness, "codex")
        form.choose(harness: "claude")
        XCTAssertEqual(form.harness, "codex")
        XCTAssertEqual(form.missing, UIText("Choose a project folder."))
        XCTAssertNil(form.launch)
        form.choose(folder: "/Users/demo/src/app/")
        XCTAssertEqual(form.folders.map(\.path), ["/Users/demo/src/app"])
        XCTAssertNil(form.missing)
        XCTAssertEqual(form.launch, AgentLaunch(harness: "codex", folder: "/Users/demo/src/app"))
    }

    /// `ps --json` with no sandbox, and `board --json` with two ended runs
    /// that `ps` no longer lists: both answer, and there is no room.
    func testPsAndBoardDecode() async throws {
        let ps = try object("ps.json")
        XCTAssertEqual(ps["api_version"] as? String, "paddock.ps/v1")
        XCTAssertEqual((ps["sandboxes"] as? [Any])?.count, 0)
        XCTAssertEqual((ps["ended"] as? [Any])?.count, 0)
        let plain = try object("board.json")
        XCTAssertEqual(plain["version"] as? Int, 1)
        XCTAssertNil(plain["api_version"], "board has `version`, not `api_version`")

        let (agents, runner) = try agents()
        await agents.loadChoices()
        await agents.refreshRuns(force: true)
        XCTAssertEqual(runner.calls(startingWith: AgentArgs.ps).count, 1)
        XCTAssertEqual(runner.calls(startingWith: AgentArgs.board).count, 1)
        XCTAssertTrue(agents.runsLoaded)
        XCTAssertTrue(agents.boardLoaded)
        XCTAssertEqual(agents.gaps, [])
        XCTAssertEqual(agents.runs, [])
        XCTAssertEqual(agents.ended, [])
        XCTAssertEqual(try PsJSON.decode(real("ps.json")), PsJSON())

        XCTAssertEqual(try BoardJSON.decode(real("board.json")).approvalsWaiting, 0)
        XCTAssertEqual(agents.board.keys.sorted(), ["074562", "58baf9"])
        let first = try XCTUnwrap(agents.board["074562"])
        XCTAssertEqual(first, BoardRunJSON(id: "074562", state: "ended", harness: "codex",
                                           project: "/private/tmp/pdk-codextest/proj",
                                           status: "the sandbox ended with exit code 0",
                                           since: ISO.date("2026-11-12T16:13:34Z")))
        XCTAssertEqual(agents.board["58baf9"]?.status, "the sandbox ended with exit code 2")
        XCTAssertEqual(agents.board["58baf9"]?.since, ISO.date("2026-11-12T16:12:15Z"))
        // The board's word of a run is a state of the launcher.
        XCTAssertEqual(AgentStateMapper.board(first.state, status: first.status), .ended(done: false))
        // A run that only the board names has no room: the rooms come
        // from `ps` and from the panes.
        XCTAssertEqual(agents.rooms, [])
        XCTAssertEqual(agents.liveRooms, [])
    }

    func object(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: real(name)) as? [String: Any], name)
    }
}
