import XCTest
@testable import PaddockKit

/// The rules of the screens: the hero action, the storage group, the age
/// of a request, the build as one progress, the toolbar and the home page.
final class ScreenTests: XCTestCase {
    static let info = GoldenInfo(version: "15.1", built: nil, sizeBytes: 25_000_000_000, dir: nil, appsUsing: 1)

    // MARK: The hero action

    func testTheHeroActionOfAnAppWithABaseImage() {
        let ready = GoldenState.ready(ScreenTests.info)
        XCTAssertEqual(HeroAction.of(.stopped, golden: ready, goldenLoaded: true), .start)
        XCTAssertEqual(HeroAction.of(.saved(since: nil), golden: ready, goldenLoaded: true), .start)
        XCTAssertEqual(HeroAction.of(.error(reason: "x"), golden: ready, goldenLoaded: true), .start)
        XCTAssertEqual(HeroAction.of(.suspended(reason: nil), golden: ready, goldenLoaded: true), .resume)
        XCTAssertEqual(HeroAction.of(.running(since: nil, windows: 1), golden: ready, goldenLoaded: true), .open)
        XCTAssertNil(HeroAction.of(.starting(.booting), golden: ready, goldenLoaded: true))
        XCTAssertNil(HeroAction.of(.stopping, golden: ready, goldenLoaded: true))
        XCTAssertNil(HeroAction.of(.blocked(reason: "x", code: "app_store"), golden: ready, goldenLoaded: true))
        XCTAssertEqual(HeroAction.of(.stopped, golden: .needsUpdate(ScreenTests.info, hostVersion: "16"), goldenLoaded: true), .start)
    }

    func testWithoutABaseImageTheActionSaysSoAndStartsTheSetup() {
        XCTAssertEqual(HeroAction.of(.stopped, golden: .none, goldenLoaded: true), .buildBaseImage)
        XCTAssertEqual(HeroAction.of(.blocked(reason: "Build the base image to start this app.", code: "no_golden"),
                                     golden: .none, goldenLoaded: true), .buildBaseImage)
        let failed = GoldenState.failed(BuildFailure(step: .download, code: "stopped", reason: ""))
        XCTAssertEqual(HeroAction.of(.stopped, golden: failed, goldenLoaded: true), .buildBaseImage)
        XCTAssertEqual(HeroAction.of(.stopped, golden: .building(BuildProgress()), goldenLoaded: true), .showBuild)
        XCTAssertEqual(HeroAction.of(.blocked(reason: "", code: "no_golden"), golden: .building(BuildProgress()),
                                     goldenLoaded: true), .showBuild)
        // A running or suspended app has its session already.
        XCTAssertEqual(HeroAction.of(.running(since: nil, windows: 0), golden: .none, goldenLoaded: true), .open)
        XCTAssertEqual(HeroAction.of(.suspended(reason: nil), golden: .none, goldenLoaded: true), .resume)
        XCTAssertEqual(HeroAction.buildBaseImage.title.english, "Build the Base Image…")
        XCTAssertNotNil(HeroAction.buildBaseImage.note)
        XCTAssertNotNil(HeroAction.showBuild.note)
        XCTAssertNil(HeroAction.start.note)
    }

    func testBeforePaddockSaidItTheActionIsStart() {
        XCTAssertEqual(HeroAction.of(.stopped, golden: .none, goldenLoaded: false), .start)
        XCTAssertNil(HeroAction.of(.blocked(reason: "", code: "no_golden"), golden: .none, goldenLoaded: false))
    }

    func testTheIdentifiersOfTheSessionButtonsStay() {
        XCTAssertEqual(HeroAction.start.identifier, "start-button")
        XCTAssertEqual(HeroAction.resume.identifier, "resume-button")
        XCTAssertEqual(HeroAction.open.identifier, "open-button")
    }

    // MARK: Storage

    private func app(_ json: String) throws -> AppJSON {
        try PaddockJSON.decoder.decode(AppJSON.self, from: Data(json.utf8))
    }

    func testBeforeTheFirstStartStorageSaysWhatWillHappen() throws {
        let zero = try app(#"{"name":"a","state":"stopped","sizes":{"app_copy":0,"data":0,"saved_state":0}}"#)
        XCTAssertEqual(StorageSummary.of(zero), .nothingYet)
        XCTAssertEqual(StorageSummary.of(try app(#"{"name":"a","state":"stopped"}"#)), .nothingYet)
        XCTAssertEqual(StorageSummary.of(try app(#"{"name":"a","state":"stopped","bytes":0}"#)), .nothingYet)
        XCTAssertFalse(StorageSummary.canClearSavedState(zero, state: .stopped))
        XCTAssertEqual(StorageSummary.nothingYetLine.english, "Nothing stored yet. The first start prepares the app.")
    }

    func testWithDataStorageShowsTheParts() throws {
        let some = try app(#"{"name":"a","state":"stopped","sizes":{"app_copy":1200000000,"data":0,"saved_state":2000000000}}"#)
        XCTAssertEqual(StorageSummary.of(some), .parts(AppSizesJSON(appCopy: 1_200_000_000, data: 0, savedState: 2_000_000_000)))
        XCTAssertTrue(StorageSummary.canClearSavedState(some, state: .stopped))
        XCTAssertFalse(StorageSummary.canClearSavedState(some, state: .running(since: nil, windows: 1)))
        XCTAssertFalse(StorageSummary.canClearSavedState(some, state: .suspended(reason: nil)))
        XCTAssertEqual(StorageSummary.of(try app(#"{"name":"a","state":"stopped","bytes":5}"#)), .total(5))
    }

    // MARK: The age of a request

    func testARequestShowsItsAge() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(RequestAge.asked(now.addingTimeInterval(-3 * 86_400), now: now)?.english, "Asked 3 d ago")
        XCTAssertEqual(RequestAge.asked(now.addingTimeInterval(-90), now: now)?.english, "Asked 1 min ago")
        XCTAssertNil(RequestAge.asked(nil, now: now))
        XCTAssertEqual(RequestAge.asked(now.addingTimeInterval(-180), now: now)?
            .resolve(TableCatalog(["Asked %@": "%@提出", "%@ min ago": "%@ 分钟前"])).text, "3 分钟前提出")
    }

    func testARequestExpiresAfterADayOrAtItsTimeLimit() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let fresh = AgentRequestJSON(id: "a", sandbox: "s", capability: "exec", created: now.addingTimeInterval(-60),
                                     expires: now.addingTimeInterval(60))
        let timedOut = AgentRequestJSON(id: "b", sandbox: "s", capability: "exec", created: now.addingTimeInterval(-600),
                                        expires: now.addingTimeInterval(-1))
        let old = AgentRequestJSON(id: "c", sandbox: "s", capability: "exec", created: now.addingTimeInterval(-3 * 86_400))
        let undated = AgentRequestJSON(id: "d", sandbox: "s", capability: "exec")
        XCTAssertFalse(RequestAge.isExpired(fresh, now: now))
        XCTAssertTrue(RequestAge.isExpired(timedOut, now: now))
        XCTAssertTrue(RequestAge.isExpired(old, now: now))
        XCTAssertFalse(RequestAge.isExpired(undated, now: now), "a request with no date is never cleared")
        let question = QuestionJSON(id: "q", app: "a", host: "h", port: 443, opened: now.addingTimeInterval(-86_400))
        XCTAssertTrue(RequestAge.isExpired(question, now: now))
        XCTAssertFalse(RequestAge.isExpired(QuestionJSON(id: "q", app: "a", host: "h", port: 443,
                                                         opened: now.addingTimeInterval(-86_399)), now: now))
        XCTAssertEqual(RequestAge.expiredLine(1).english, "1 request is older than a day or timed out.")
        XCTAssertEqual(RequestAge.expiredLine(2).english, "2 requests are older than a day or timed out.")
    }

    // MARK: The build as one progress

    func testTheBuildIsOneProgress() {
        var progress = BuildProgress()
        XCTAssertEqual(progress.overallFraction, 0)
        XCTAssertEqual(progress.headline.english, "Downloading macOS")
        XCTAssertEqual(progress.estimate.english, "Usually 10 to 30 minutes in total")
        let start = Date(timeIntervalSince1970: 0)
        progress.apply(SetupJSON(step: "download", bytes: 5_000_000_000, total: 10_000_000_000, rate: 10_000_000, time: start))
        XCTAssertEqual(progress.overallFraction, 0.3, accuracy: 0.0001)
        progress.apply(SetupJSON(step: "download", bytes: 5_000_000_000, total: 10_000_000_000, rate: 10_000_000,
                                 time: start.addingTimeInterval(31)))
        XCTAssertEqual(progress.estimate.english, "9 min left")
        progress.apply(SetupJSON(step: "download", bytes: 5_000_000_000, total: 10_000_000_000, paused: true,
                                 time: start.addingTimeInterval(40)))
        XCTAssertEqual(progress.headline.english, "Download paused")
        XCTAssertEqual(progress.estimate.english, "Paused. Resume continues where it stopped.")
        var last = progress.overallFraction
        for (step, headline) in [("install", "Installing macOS"), ("guided", "Setting up macOS"), ("seal", "Sealing the base image")] {
            progress.apply(SetupJSON(step: step, time: start.addingTimeInterval(100)))
            XCTAssertGreaterThan(progress.overallFraction, last, step)
            XCTAssertEqual(progress.headline.english, headline)
            last = progress.overallFraction
        }
        XCTAssertLessThan(last, 1)
        progress.apply(SetupJSON(step: "done"))
        XCTAssertEqual(progress.overallFraction, 1)
        XCTAssertEqual(progress.headline.english, "Base image ready")
    }

    // MARK: Chrome

    func testTheLayoutSwitchShowsOnlyWhereItActs() {
        XCTAssertFalse(ToolbarRule.showsLayoutSwitch(.questions, apps: 3, agents: 3))
        XCTAssertFalse(ToolbarRule.showsLayoutSwitch(.baseImage, apps: 3, agents: 3))
        XCTAssertTrue(ToolbarRule.showsLayoutSwitch(.app("a"), apps: 1, agents: 0))
        XCTAssertTrue(ToolbarRule.showsLayoutSwitch(nil, apps: 1, agents: 0))
        XCTAssertFalse(ToolbarRule.showsLayoutSwitch(nil, apps: 0, agents: 2), "an empty Apps page has one layout")
        XCTAssertTrue(ToolbarRule.showsLayoutSwitch(.agents, apps: 0, agents: 1))
        XCTAssertTrue(ToolbarRule.showsLayoutSwitch(.agent("k"), apps: 0, agents: 1))
        XCTAssertFalse(ToolbarRule.showsLayoutSwitch(.agents, apps: 5, agents: 0))
    }

    func testTheWindowTitleIsThePage() {
        XCTAssertEqual(WindowTitle.of(.app("notes"), appTitle: "Sample Notes", agentTitle: nil).english, "Sample Notes")
        XCTAssertEqual(WindowTitle.of(.questions, appTitle: nil, agentTitle: nil).english, "Questions")
        XCTAssertEqual(WindowTitle.of(.baseImage, appTitle: nil, agentTitle: nil).english, "Base image")
        XCTAssertEqual(WindowTitle.of(.agents, appTitle: nil, agentTitle: nil).english, "Agents")
        XCTAssertEqual(WindowTitle.of(.agent("k"), appTitle: nil, agentTitle: UIText("%@ in %@", "Codex", "shop")).english,
                       "Codex in shop")
        XCTAssertEqual(WindowTitle.of(nil, appTitle: nil, agentTitle: nil).english, "paddock for Mac")
    }

    func testTheHomePageSaysWhatToDoNext() {
        XCTAssertEqual(NextStep.of(waiting: 2, agents: 1, apps: 0), .answer(2))
        XCTAssertEqual(NextStep.of(waiting: 0, agents: 0, apps: 0), .firstAgent)
        XCTAssertEqual(NextStep.of(waiting: 0, agents: 0, apps: 2), .newAgent)
        XCTAssertEqual(NextStep.answer(1).title.english, "1 request waits for your answer")
        XCTAssertEqual(NextStep.answer(2).title.english, "2 requests wait for your answer")
        XCTAssertEqual(NextStep.answer(2).action.english, "Show the Requests")
        XCTAssertEqual(NextStep.firstAgent.action.english, "New Agent…")
        XCTAssertNil(NextStep.summary(agents: 0, apps: 0))
        XCTAssertEqual(NextStep.summary(agents: 1, apps: 0)?.english, "1 agent")
        XCTAssertEqual(NextStep.summary(agents: 2, apps: 3)?.english, "2 agents · 3 apps")
        XCTAssertEqual(NextStep.summary(agents: 0, apps: 1)?.english, "1 app")
    }

    func testAnEmptyAgentsPageSaysWhenPaddockFoundNoAgent() {
        XCTAssertEqual(AgentsEmpty.of(loaded: false, installed: 0), .noRuns)
        XCTAssertEqual(AgentsEmpty.of(loaded: true, installed: 2), .noRuns)
        XCTAssertEqual(AgentsEmpty.of(loaded: true, installed: 0), .noneInstalled)
        XCTAssertEqual(AgentsEmpty.noRuns.title.english, "No agents yet")
        XCTAssertEqual(AgentsEmpty.noneInstalled.title.english, "No agent found on this Mac")
    }

    // MARK: Features of a newer paddock

    func testAMissingCommandIsOneQuietLineNeverAPageOfCannot() {
        XCTAssertEqual(ComingFeature.needs.english, "Needs paddock 0.2.4")
        for feature in ComingFeature.allCases {
            let promise = feature.promise.english
            XCTAssertFalse(promise.lowercased().contains("cannot"), promise)
            XCTAssertFalse(promise.lowercased().contains("not "), promise)
            XCTAssertFalse(promise.lowercased().contains("update"), promise)
            XCTAssertTrue(promise.hasSuffix("."), promise)
            XCTAssertEqual(feature.line.english, promise + " Needs paddock 0.2.4.")
        }
        XCTAssertEqual(ComingFeature.rules.promise.english, "The servers that this app may reach show here.")
    }

    func testAnActionOfANewerPaddockSaysWhatItNeedsWithNoCommand() throws {
        let unknown = CommandError.failed(status: 2, line: "error: unrecognized subcommand 'keep'")
        XCTAssertEqual(NetLoad.of(unknown), .needsNewerPaddock)
        // The texts of the three actions: one line each, no "Update paddock:".
        for feature in [ComingFeature.changeRules, .sessionClipboard, .keepFolder] {
            XCTAssertTrue(feature.line.english.hasSuffix("Needs paddock 0.2.4."), feature.line.english)
        }
        let sources = Fixtures.root.deletingLastPathComponent().appendingPathComponent("PaddockKit/Sources/PaddockKit/Network/NetworkModel.swift")
        let model = try String(contentsOf: sources, encoding: .utf8)
        XCTAssertFalse(model.contains("This paddock cannot"), "a text of 'cannot' in the network model")
        XCTAssertFalse(model.contains("Update paddock:"))
        XCTAssertEqual(model.components(separatedBy: "ComingFeature.").count - 1, 3)
    }

    func testTheNetworkModeHasItsOwnNote() {
        XCTAssertEqual(NetworkCopy.modeNote(.ask).english, "paddock asks you the first time the app reaches a new server.")
        XCTAssertNotEqual(NetworkCopy.modeNote(.allowlist), NetworkCopy.modeNote(.none))
    }

    func testTheNetworkLevelOfARunIsNamedInPlainWords() {
        XCTAssertEqual(AgentNetwork.text("api"), AgentNetwork.api.title)
        XCTAssertEqual(AgentNetwork.text("none"), AgentNetwork.none.title)
        XCTAssertEqual(AgentNetwork.text("mesh").english, "mesh")
        XCTAssertEqual(AgentNetwork.text("mesh").resolve(TableCatalog(["Not known": "未知"])),
                       ResolvedText(text: "未知", details: "mesh"))
    }
}
