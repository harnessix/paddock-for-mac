import XCTest
@testable import PaddockKit

/// FLOW1: the messages of the launcher and the next screen of each action.
///
/// - Every notice comes from the launcher: the event stream becomes
///   notices (`NoticeBook`), each with the place a click goes to.
/// - A line of paddock's CLI is never the message: it goes under Details.
/// - Add App with no base image keeps the app, and adds it by itself when
///   the base image is ready.
/// - Remove selects the next row. Stop says "Stopped".
@MainActor
final class FlowOneTests: XCTestCase {
    // MARK: Plain errors

    // A line of the CLI is never the message. It is the details.
    func testALineOfTheCLIIsNeverTheMessage() {
        let lines = [
            "paddock: error: the profile store is locked by pid 811 (os error 35)",
            "error: unexpected argument '--manual' found",
            "sample-mail runs. Stop it first: paddock app stop sample-mail",
            "The golden image is not sealed. Run paddock macvm setup first.",
            "Needs 40.0 GiB on the volume of /Users/u/macvm, 12.1 GiB free.",
            "fake paddock: no fixture for app frobnicate",
            "thread 'main' panicked at src/cli/app.rs:42",
        ]
        for line in lines {
            let problem = PlainError.problem(line)
            XCTAssertNotEqual(problem.message.english, line)
            XCTAssertFalse(problem.message.english.contains(line), line)
            XCTAssertEqual(problem.details, line, "the line is kept for Details")
            // A sentence with a next step, in plain words.
            XCTAssertTrue(problem.message.english.hasSuffix("."), problem.message.english)
            for word in ["error:", "paddock app ", "os error", "panicked", "--"] {
                XCTAssertFalse(problem.message.english.contains(word), "\(problem.message.english) has \(word)")
            }
        }
        XCTAssertEqual(PlainError.sentence("sample-mail runs. Stop it first: paddock app stop sample-mail"), PlainError.stillRunning)
        XCTAssertEqual(PlainError.sentence("The golden image is not sealed. Run paddock macvm setup first."), PlainError.needsBaseImage)
        XCTAssertEqual(PlainError.sentence("Needs 40.0 GiB on the volume, 12.1 GiB free."), PlainError.noSpace)
        XCTAssertEqual(PlainError.sentence("error: unexpected argument '--manual' found"), PlainError.oldPaddock)
        XCTAssertEqual(PlainError.sentence("thread 'main' panicked"), PlainError.generic)
        XCTAssertEqual(PlainError.sentence(""), PlainError.generic)
        XCTAssertNil(PlainError.problem("").details)
    }

    // A sentence that the launcher wrote has no line behind it.
    func testTheLaunchersOwnSentencesHaveNoDetails() {
        for own in [LibraryCopy.offline.english, LibraryCopy.noAnswer.english, "paddock is not installed",
                    "paddock is not reachable", "paddock did not answer", PlainError.notConfirmed.english] {
            let problem = PlainError.problem(own)
            XCTAssertNil(problem.details, own)
            XCTAssertTrue(problem.message.english.hasSuffix("."), problem.message.english)
        }
        XCTAssertEqual(PlainError.problem("paddock is not installed").message, LibraryCopy.offline)
    }

    // A failed command: the title, a plain sentence, the line under Details.
    func testAFailedCommandShowsASentenceAndKeepsTheLine() {
        let line = "paddock: error: cannot remove sample-mail: the profile store is locked (os error 35)"
        let error = LauncherError.command(title: UIText("%@ was not removed", "Sample Mail"), line: line)
        XCTAssertEqual(error.title?.english, "Sample Mail was not removed")
        XCTAssertEqual(error.cliLine, line)
        XCTAssertEqual(error.details, line)
        XCTAssertEqual(error.message, PlainError.generic)
        XCTAssertEqual(error.problem, InlineProblem(message: PlainError.generic, details: line))
        // The typed errors keep their own sentence and have no details.
        let typed = LauncherError.twoRunning(app: "Notebook", running: ["A", "B"])
        XCTAssertNil(typed.cliLine)
        XCTAssertNil(typed.details)
        XCTAssertEqual(typed.message, typed.body)
        let copy = LauncherError.appCopyFailed(app: "Notebook", line: "cp: No space left on device")
        XCTAssertEqual(copy.details, "cp: No space left on device")
        XCTAssertEqual(copy.message, PlainError.noSpace)
    }

    // The failed build: the reason of paddock's report as it is; the last
    // line of a build that ended by itself under Details.
    func testBuildFailureProblem() {
        let reported = BuildFailure(step: .download, code: "download_interrupted",
                                    reason: "The download of the restore image stopped: the connection closed.")
        XCTAssertFalse(reported.reasonIsRaw)
        XCTAssertEqual(reported.problem.message.english, reported.reason)
        XCTAssertNil(reported.problem.details)

        let raw = BuildFailure(step: nil, code: "exited", reason: "paddock: error: hdiutil: attach failed (os error 5)")
        XCTAssertTrue(raw.reasonIsRaw)
        XCTAssertEqual(raw.problem.message.english,
                       "The build stopped before the base image was ready. Try Again continues where it stopped.")
        XCTAssertEqual(raw.problem.details, raw.reason)

        let silent = BuildFailure(step: nil, code: "exited", reason: "")
        XCTAssertNil(silent.problem.details)
        XCTAssertFalse(silent.problem.message.english.isEmpty)
        // A build child that paddock could not start: the launcher's own sentence.
        let away = BuildFailure(step: nil, code: "exited", reason: "paddock is not installed")
        XCTAssertEqual(away.problem, InlineProblem(message: LibraryCopy.offline))
    }

    // MARK: Notices

    func session(_ app: String, _ state: String, reason: String? = nil, home: String? = nil) -> PaddockEvent {
        .session(SessionEvent(app: app, state: state, phase: nil, since: nil, windows: nil, reason: reason,
                              blockCode: nil, crash: nil, connected: nil, nextStart: nil, home: home, text: nil, t: nil))
    }

    // An app that ends in an error: one notice, with its room as the target.
    func testASessionErrorIsToldOnce() {
        var book = NoticeBook()
        let first = book.notices(for: session("sample-mail", "error", reason: "The VM stopped: out of memory"),
                                 appTitle: "Sample Mail")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].kind, .appFailed)
        XCTAssertEqual(first[0].title.english, "Sample Mail stopped unexpectedly")
        XCTAssertEqual(first[0].body.english, "The VM stopped: out of memory")
        XCTAssertEqual(first[0].target, .app("sample-mail"))
        XCTAssertTrue(first[0].isProblem)
        XCTAssertTrue(first[0].showsInWindow)
        // The same state again is not news.
        XCTAssertTrue(book.notices(for: session("sample-mail", "error", reason: "x"), appTitle: "Sample Mail").isEmpty)
        // An agent change of the guest does not end the error.
        XCTAssertTrue(book.notices(for: session("sample-mail", "agent"), appTitle: "Sample Mail").isEmpty)
        XCTAssertTrue(book.notices(for: session("sample-mail", "error"), appTitle: "Sample Mail").isEmpty)
        // After a run, the next error is news again, with a new id.
        XCTAssertTrue(book.notices(for: session("sample-mail", "running"), appTitle: "Sample Mail").isEmpty)
        let again = book.notices(for: session("sample-mail", "error"), appTitle: "Sample Mail")
        XCTAssertEqual(again.count, 1)
        XCTAssertNotEqual(again[0].id, first[0].id)
        XCTAssertEqual(again[0].body.english, "Open paddock for Mac to see what happened.")
        // Instance 2 is its own room.
        let second = book.notices(for: session("sample-mail", "error", home: "instance-2"), appTitle: "Sample Mail 2")
        XCTAssertEqual(second.first?.target, .app("sample-mail--2"))
        // A blocked app.
        let blocked = book.notices(for: session("notebook", "blocked", reason: "Build the base image to start this app."),
                                   appTitle: "Notebook")
        XCTAssertEqual(blocked.first?.kind, .appBlocked)
        XCTAssertEqual(blocked.first?.title.english, "Notebook cannot start")
        // A normal stop, a start and a save tell nothing.
        for state in ["starting", "running", "stopping", "stopped", "saved", "removed", "added"] {
            XCTAssertTrue(book.notices(for: session("other", state), appTitle: "Other").isEmpty, state)
        }
    }

    func testTheBuildTellsItsEndOnce() {
        var book = NoticeBook()
        XCTAssertTrue(book.notices(for: .setup(SetupJSON(step: "download", bytes: 1, total: 2))).isEmpty)
        let failure = SetupFailureJSON(code: "no_space", reason: "Needs 40.0 GiB, 12.1 GiB free.")
        let failed = book.notices(for: .setup(SetupJSON(step: "install", failed: failure)))
        XCTAssertEqual(failed.map(\.kind), [.buildFailed])
        XCTAssertEqual(failed[0].title.english, "Base image not built")
        XCTAssertEqual(failed[0].body.english, "Needs 40.0 GiB, 12.1 GiB free.")
        XCTAssertEqual(failed[0].target, .baseImage)
        // The same line comes from the build child and from the event stream.
        XCTAssertTrue(book.notices(for: .setup(SetupJSON(step: "install", failed: failure))).isEmpty)
        // Try Again, then done: told once, also when `golden ready` follows.
        XCTAssertTrue(book.notices(for: .setup(SetupJSON(step: "install"))).isEmpty)
        let done = book.notices(for: .setup(SetupJSON(step: "done")))
        XCTAssertEqual(done.map(\.kind), [.buildReady])
        XCTAssertEqual(done[0].title.english, "Base image ready")
        XCTAssertEqual(done[0].target, .baseImage)
        XCTAssertTrue(book.notices(for: .setup(SetupJSON(step: "done"))).isEmpty)
        XCTAssertTrue(book.notices(for: .golden(op: "ready")).isEmpty)
        // A rebuild is news again.
        XCTAssertTrue(book.notices(for: .golden(op: "removed")).isEmpty)
        XCTAssertEqual(book.notices(for: .golden(op: "ready")).map(\.kind), [.buildReady])
        // The same failure after a new try is told again.
        XCTAssertTrue(book.notices(for: .setup(SetupJSON(step: "download"))).isEmpty)
        XCTAssertEqual(book.notices(for: .setup(SetupJSON(step: "install", failed: failure))).count, 1)
    }

    func testPausedQuestionsAreTold() throws {
        var book = NoticeBook()
        let lines = Fixtures.core("launcher/question.jsonl").path
        let events = try String(contentsOfFile: lines, encoding: .utf8).split(separator: "\n")
            .compactMap { PaddockEvent.decode(line: String($0)) }
        var told: [Notice] = []
        for event in events { told += book.notices(for: event, appTitle: "Sample Notes") }
        // Two pauses in the core fixture; open and answered tell nothing here.
        XCTAssertEqual(told.map(\.kind), [.questionsPaused, .questionsPaused])
        XCTAssertEqual(told[0].title.english, "Questions paused")
        XCTAssertEqual(told[0].body.english, "Sample Notes asked 23 times in a minute. paddock paused the questions.")
        XCTAssertEqual(told[0].target, .questions)
        XCTAssertNotEqual(told[0].id, told[1].id)
    }

    // A `notice` line of the stream shows in paddock's words.
    func testANoticeLineOfTheStream() {
        let line = #"{"v":1,"t":"2026-11-13T09:00:00Z","kind":"notice","id":"n-1","title":"Sample Mail","text":"Sample Mail was updated on this Mac.","app":"sample-mail"}"#
        let event = PaddockEvent.decode(line: line)
        XCTAssertEqual(event, .notice(NoticeEvent(id: "n-1", title: "Sample Mail", text: "Sample Mail was updated on this Mac.",
                                                  app: "sample-mail")))
        var book = NoticeBook()
        let told = book.notices(for: event!, appTitle: "Sample Mail")
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told[0].kind, .message)
        XCTAssertEqual(told[0].id, "notice-n-1")
        XCTAssertEqual(told[0].title.english, "Sample Mail")
        XCTAssertEqual(told[0].body.english, "Sample Mail was updated on this Mac.")
        XCTAssertEqual(told[0].target, .app("sample-mail"))

        // The other names of the words, and the targets.
        let run = PaddockEvent.decode(line: #"{"v":1,"kind":"notify","summary":"Claude Code","message":"The run ended.","sandbox":"claude-1a2b3c"}"#)
        XCTAssertEqual(run, .notice(NoticeEvent(title: "Claude Code", text: "The run ended.", run: "claude-1a2b3c")))
        if case .notice(let e)? = run { XCTAssertEqual(e.target, .agent("claude-1a2b3c")) } else { XCTFail("no notice") }
        let setup = PaddockEvent.decode(line: #"{"v":1,"kind":"notice","body":"The base image is sealed.","topic":"setup"}"#)
        if case .notice(let e)? = setup {
            XCTAssertEqual(e.title, "paddock")
            XCTAssertEqual(e.target, .baseImage)
        } else {
            XCTFail("no notice")
        }
        let question = NoticeEvent(title: "x", text: "y", about: "question")
        XCTAssertEqual(question.target, .questions)
        XCTAssertNil(NoticeEvent(title: "x", text: "y").target)
        // A notice with no words is a known kind with nothing to show.
        XCTAssertEqual(PaddockEvent.decode(line: #"{"v":1,"kind":"notice"}"#), .unknown(kind: "notice"))
        // Without an id, two different notices do not collide.
        let a = book.notices(for: .notice(NoticeEvent(title: "a", text: "one")))
        let b = book.notices(for: .notice(NoticeEvent(title: "a", text: "two")))
        XCTAssertNotEqual(a[0].id, b[0].id)
    }

    // The other kinds of the stream tell nothing: they are states, not news.
    func testTheQuietKinds() throws {
        var book = NoticeBook()
        for name in ["launcher/disk.jsonl", "launcher/grant.jsonl", "launcher/stream.jsonl"] {
            let text = try String(contentsOf: Fixtures.core(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let event = try XCTUnwrap(PaddockEvent.decode(line: String(line)), String(line))
                XCTAssertTrue(book.notices(for: event).isEmpty, String(line))
            }
        }
        // The session fixture of core ends in an error of sample-mail.
        let text = try String(contentsOf: Fixtures.core("launcher/session.jsonl"), encoding: .utf8)
        var told: [Notice] = []
        for line in text.split(separator: "\n") {
            let event = try XCTUnwrap(PaddockEvent.decode(line: String(line)))
            told += book.notices(for: event, appTitle: NoticeBook.appKey(of: event))
        }
        XCTAssertEqual(told.map(\.kind), [.appFailed])
        XCTAssertEqual(told[0].title.english, "sample-mail stopped unexpectedly")
        XCTAssertEqual(told[0].body.english, "session ended without a save")
    }

    // The store shows a notice of the stream in the window and hands it to
    // the app once.
    func testTheStoreShowsAndHandsOverEachNoticeOnce() async throws {
        let h = try await Harness("library")
        var got: [Notice] = []
        h.store.onNotice = { got.append($0) }
        let line = #"{"v":1,"t":"2026-11-08T10:01:00Z","kind":"session","app":"sample-mail","home":"default","state":"error","text":"session ended without a save"}"#
        h.events.send(line)
        await waitUntil { got.count == 1 }
        XCTAssertEqual(got[0].title.english, "Sample Mail stopped unexpectedly", "the name on screen, not the profile name")
        XCTAssertEqual(got[0].target, .app("sample-mail"))
        XCTAssertEqual(h.store.notices, got)
        h.events.send(line)
        h.events.send(#"{"v":1,"kind":"notice","id":"n-9","title":"Sample Notes","text":"Updated.","app":"sample-notes"}"#)
        await waitUntil { got.count == 2 }
        XCTAssertEqual(got.map(\.kind), [.appFailed, .message])
        XCTAssertEqual(h.store.notices.map(\.kind), [.message, .appFailed], "the newest first")
        // The same id is not posted twice.
        h.store.post(got[1])
        XCTAssertEqual(got.count, 2)
        h.store.dismissNotice(got[1].id)
        XCTAssertEqual(h.store.notices.map(\.kind), [.appFailed])
        // The window keeps the last few.
        for index in 0..<10 {
            h.store.post(Notice(id: "extra-\(index)", kind: .message, title: UIText("t"), body: UIText("b"), target: nil))
        }
        XCTAssertEqual(h.store.notices.count, LauncherStore.noticesKept)
        XCTAssertEqual(h.store.notices.first?.id, "extra-9")
        XCTAssertEqual(got.count, 12)
        // The notices of the questions and the agents do not push a line
        // of the window out.
        for index in 0..<10 {
            h.store.post(Notice(id: "question-x\(index)", kind: .question, title: UIText("t"), body: UIText("b"),
                                target: .questions, card: "x\(index)"))
        }
        XCTAssertEqual(h.store.notices.filter(\.showsInWindow).count, LauncherStore.noticesKept)
        XCTAssertEqual(h.store.notices.filter { !$0.showsInWindow }.count, LauncherStore.noticesKept)
        XCTAssertEqual(h.store.notices.first(where: \.showsInWindow)?.id, "extra-9")
    }

    // The notice of an answered question leaves the window.
    func testANoticeOfAnAnsweredQuestionGoes() async throws {
        let h = try await Harness("questions")
        let question = try XCTUnwrap(h.store.questions.first)
        let notice = Notice(question: question)
        XCTAssertEqual(notice.id, "question-" + question.id)
        XCTAssertEqual(notice.target, .questions)
        XCTAssertEqual(notice.card, question.id)
        XCTAssertFalse(notice.showsInWindow, "the Questions badge shows it")
        h.store.post(notice)
        XCTAssertEqual(h.store.notices.count, 1)
        h.events.send(#"{"v":1,"kind":"question","state":"answered","id":"\#(question.id)","answer":"deny"}"#)
        await waitUntil { h.store.notices.isEmpty }
    }

    // A click on a notification finds its place again from plain strings.
    func testTheRouteOfANotification() {
        for item in [SidebarItem.questions, .baseImage, .agents, .app("sample-notes--2"), .agent("pane-1-ab12")] {
            let notice = Notice(id: "x", kind: .message, title: UIText("t"), body: UIText("b"), target: item, card: "r-1")
            let back = NoticeRoute.destination(NoticeRoute.userInfo(notice))
            XCTAssertEqual(back.target, item)
            XCTAssertEqual(back.card, "r-1")
        }
        let plain = Notice(id: "x", kind: .message, title: UIText("t"), body: UIText("b"), target: nil)
        XCTAssertTrue(NoticeRoute.userInfo(plain).isEmpty)
        XCTAssertNil(NoticeRoute.destination([:]).target)
        XCTAssertNil(NoticeRoute.item("app"))
        // The notifications of the launcher before FLOW1.
        XCTAssertEqual(NoticeRoute.destination(["agent": "run-1", "kind": "waiting"]).target, .questions)
        XCTAssertEqual(NoticeRoute.destination(["agent": "run-1", "kind": "ended"]).target, .agent("run-1"))
        let old = NoticeRoute.destination(["question": "q1"])
        XCTAssertEqual(old.target, .questions)
        XCTAssertEqual(old.card, "q1")
    }

    // The notice of a waiting request opens the Questions list on its
    // card; the end of a run opens its room.
    func testAgentNoticesKnowTheirCard() {
        let waiting = AgentNotice(id: "agent-request-r-17", kind: .waiting, key: "pane-1",
                                  title: UIText("Claude Code in shop is waiting for you"), body: UIText("x"))
        let notice = Notice(agent: waiting)
        XCTAssertEqual(notice.kind, .agentWaiting)
        XCTAssertEqual(notice.target, .questions)
        XCTAssertEqual(notice.card, "r-17")
        XCTAssertEqual(notice.id, waiting.id)
        XCTAssertFalse(notice.showsInWindow)
        let ended = Notice(agent: AgentNotice(id: "agent-end-run-1", kind: .ended, key: "pane-1", title: UIText("a"), body: UIText("b")))
        XCTAssertEqual(ended.target, .agent("pane-1"))
        XCTAssertNil(ended.card)
        let failed = Notice(agent: AgentNotice(id: "agent-end-run-2", kind: .failed, key: "run-2", title: UIText("a"), body: UIText("b")))
        XCTAssertEqual(failed.kind, .agentFailed)
        XCTAssertTrue(failed.isProblem)
    }

    // MARK: The first app without a base image

    func testTheAppThatWaitsSaysWhatHappensNext() {
        let pending = PendingAdd(path: "/Applications/Notebook.app")
        XCTAssertEqual(pending.title, "Notebook")
        XCTAssertEqual(pending.phase, .waiting)
        XCTAssertEqual(pending.status(golden: .none).english, "Needs the base image")
        XCTAssertEqual(pending.status(golden: .building(BuildProgress())).english, "Waits for the base image")
        XCTAssertEqual(pending.next(golden: .building(BuildProgress())).english,
                       "Notebook is added when the base image is ready. You do not need to wait here.")
        XCTAssertEqual(pending.pose(golden: .building(BuildProgress())), .work)
        let failed = GoldenState.failed(BuildFailure(step: nil, code: "stopped", reason: "x"))
        XCTAssertEqual(pending.pose(golden: failed), .blocked)
        XCTAssertNil(pending.problem)
        let refused = PendingAdd(path: "/Applications/Notebook.app", phase: .failed("paddock: error: locked (os error 35)"))
        XCTAssertEqual(refused.status(golden: .none).english, "Not added")
        XCTAssertEqual(refused.next(golden: .none).english, "Notebook was not added")
        XCTAssertEqual(refused.problem, InlineProblem(message: PlainError.generic, details: "paddock: error: locked (os error 35)"))
        XCTAssertEqual(refused.pose(golden: .none), .blocked)
    }

    // Add App with no base image: the app waits, the build runs, and the
    // add goes on by itself. The window selects the new app.
    func testTheAddGoesOnByItselfAfterTheBuild() async throws {
        let h = try await Harness("first-app")
        XCTAssertTrue(h.store.addNeedsBaseImage)
        var told: [Notice] = []
        h.store.onNotice = { told.append($0) }
        h.store.selection = .baseImage
        h.store.keepForBaseImage("/Applications/Notebook.app")
        XCTAssertEqual(h.store.pendingAdd, PendingAdd(path: "/Applications/Notebook.app"))
        XCTAssertTrue(h.calls(["app", "add"]).isEmpty, "nothing is added before the base image is there")

        h.store.build()
        let feed = h.runner.feed(LibraryArgs.setup(ipsw: nil, resume: false))
        await waitUntil { feed.isOpen }
        feed.send(#"{"v":1,"t":"2026-11-06T10:00:02Z","kind":"setup","step":"fetch","bytes":0,"total":14000000000,"paused":false,"stopped":false}"#)
        await waitUntil { if case .building = h.store.golden { return true } else { return false } }
        XCTAssertEqual(h.store.pendingAdd?.phase, .waiting, "the app waits while the image builds")
        XCTAssertEqual(h.store.selection, .baseImage)

        feed.send(#"{"v":1,"t":"2026-11-06T11:30:00Z","kind":"setup","step":"sealed","paused":false,"stopped":false}"#)
        feed.finish()
        await waitUntil { h.store.selection == .app("notebook") }
        XCTAssertTrue(h.store.golden.isReady)
        XCTAssertNil(h.store.pendingAdd)
        XCTAssertNotNil(h.store.app(named: "notebook"))
        XCTAssertEqual(h.store.openRoom, .app("notebook"), "the Rooms layout opens the room")
        XCTAssertEqual(h.store.detailTab, .overview)
        XCTAssertEqual(h.calls(["app", "add", "/Applications/Notebook.app", "--dry-run"]).count, 1)
        XCTAssertEqual(h.calls(["app", "add", "/Applications/Notebook.app", "--name"]).map(\.args),
                       [["app", "add", "/Applications/Notebook.app", "--name", "notebook", "--memory", "6G", "--json"]])
        XCTAssertEqual(h.calls(["app", "install"]).map(\.args), [["app", "install", "notebook"]])
        await waitUntil { told.contains { $0.kind == .appAdded } }
        XCTAssertEqual(told.map(\.kind), [.buildReady, .appAdded])
        XCTAssertEqual(told.last?.title.english, "Notebook is ready")
        XCTAssertEqual(told.last?.target, .app("notebook"))
    }

    // The end of the build reads the state past the 5 s gate: the page
    // never stays on the steps of a build that is over.
    func testTheEndOfABuildReadsTheStateAtOnce() async throws {
        let h = try await Harness("first-app")
        let before = h.calls(["macvm", "status"]).count
        h.store.build()
        let feed = h.runner.feed(LibraryArgs.setup(ipsw: nil, resume: false))
        await waitUntil { feed.isOpen }
        // The build ends with no line at all, in the same second.
        feed.finish()
        await waitUntil { !h.store.buildRunning }
        await waitUntil { h.calls(["macvm", "status"]).count > before }
        await waitUntil { h.store.golden.isReady }
    }

    // A refused add stays with the app, as a problem with Try Again.
    func testARefusedAddStaysWithTheApp() async throws {
        let h = try await Harness("first-app")
        let line = "paddock: error: the profile store is locked by pid 811 (os error 35)"
        h.runner.reset(prefix: "app add /Applications/Notebook.app --name")
        h.runner.on(prefix: "app add /Applications/Notebook.app --name",
                    output: CommandOutput(status: 1, stdout: Data(), stderr: line + "\n"))
        var told: [Notice] = []
        h.store.onNotice = { told.append($0) }
        h.store.selection = .baseImage
        h.store.keepForBaseImage("/Applications/Notebook.app")
        await h.store.reloadStatusNow()
        XCTAssertTrue(h.store.golden.isReady)
        await waitUntil { if case .failed? = h.store.pendingAdd?.phase { return true } else { return false } }
        XCTAssertEqual(h.store.pendingAdd?.phase, .failed(line))
        XCTAssertEqual(h.store.pendingAdd?.problem, InlineProblem(message: PlainError.generic, details: line))
        XCTAssertEqual(h.store.selection, .baseImage, "the error shows where the add was")
        XCTAssertEqual(told.map(\.kind), [.addFailed])
        XCTAssertEqual(told[0].title.english, "Notebook was not added")
        XCTAssertFalse(told[0].body.english.contains("os error"), "the notification has no line of the CLI")
        XCTAssertEqual(told[0].target, .baseImage)

        // Try Again, with a paddock that works now.
        h.runner.reset(prefix: "app add /Applications/Notebook.app --name")
        h.runner.on(prefix: "app add /Applications/Notebook.app --name",
                    output: CommandOutput(status: 0, stdout: try Fixtures.data("add-report-ok.json"), stderr: ""))
        h.store.retryPendingAdd()
        await waitUntil { h.store.selection == .app("notebook") }
        XCTAssertNil(h.store.pendingAdd)
    }

    // paddock refuses the app itself: the reason stays with the app.
    func testARefusedReviewStaysWithTheApp() async throws {
        let h = try await Harness("first-app")
        h.runner.reset(prefix: "app add /Applications/Notebook.app --dry-run")
        h.runner.on(prefix: "app add /Applications/Notebook.app --dry-run",
                    output: CommandOutput(status: 1, stdout: try Fixtures.data("add-review-app-store.json"), stderr: ""))
        h.store.keepForBaseImage("/Applications/Notebook.app")
        await h.store.reloadStatusNow()
        await waitUntil { if case .failed? = h.store.pendingAdd?.phase { return true } else { return false } }
        XCTAssertTrue(h.calls(["app", "add", "/Applications/Notebook.app", "--name"]).isEmpty)
        // Do Not Add: nothing waits any more.
        h.store.dropPendingAdd()
        XCTAssertNil(h.store.pendingAdd)
        h.store.retryPendingAdd()
        XCTAssertNil(h.store.pendingAdd)
    }

    // An app that is in paddock already is shown, not added again.
    func testAnAppThatIsThereAlreadyIsShown() async throws {
        let h = try await Harness("first-app")
        h.runner.reset(prefix: "app add /Applications/Notebook.app --dry-run")
        h.runner.on(prefix: "app add /Applications/Notebook.app --dry-run",
                    output: CommandOutput(status: 1, stdout: try Fixtures.data("add-review-existing.json"), stderr: ""))
        h.store.keepForBaseImage("/Applications/Notebook.app")
        await h.store.reloadStatusNow()
        await waitUntil { h.store.pendingAdd == nil }
        XCTAssertEqual(h.store.selection, .app("sample-notes"))
        XCTAssertTrue(h.calls(["app", "add", "/Applications/Notebook.app", "--name"]).isEmpty)
    }

    // With a base image, the app that is kept is added at once.
    func testKeepWithABaseImageAddsAtOnce() async throws {
        let h = try await Harness("drop")
        XCTAssertTrue(h.store.golden.isReady)
        h.store.keepForBaseImage("/Applications/Notebook.app")
        XCTAssertEqual(h.store.pendingAdd?.phase, .adding)
        await waitUntil { h.store.selection == .app("notebook") }
        XCTAssertNil(h.store.pendingAdd)
    }

    // MARK: The next screen

    // Remove: the next row, else the row before, else the empty state.
    func testRemoveSelectsTheNextRow() {
        let keys = ["a", "b", "b--2", "c"]
        XCTAssertEqual(LauncherStore.neighbor(of: "a", in: keys, removing: ["a"]), "b")
        XCTAssertEqual(LauncherStore.neighbor(of: "b", in: keys, removing: ["b", "b--2"]), "c", "every instance goes")
        XCTAssertEqual(LauncherStore.neighbor(of: "b--2", in: keys, removing: ["b", "b--2"]), "c")
        XCTAssertEqual(LauncherStore.neighbor(of: "c", in: keys, removing: ["c"]), "b--2", "the last row: the one before")
        XCTAssertNil(LauncherStore.neighbor(of: "a", in: ["a"], removing: ["a"]), "the empty state")
        XCTAssertEqual(LauncherStore.neighbor(of: "x", in: keys, removing: ["a"]), "b", "an unknown row: the first that stays")
        XCTAssertNil(LauncherStore.neighbor(of: "x", in: [], removing: []))
    }

    func testRemoveNeverLeavesAnEmptyDetail() async throws {
        let h = try await Harness("ready")
        XCTAssertEqual(h.store.apps.map(\.key), ["Sample Notes", "Sample Mail"])
        h.store.selection = .app("Sample Mail")
        await h.store.removeApp("Sample Mail", deleteData: false)
        XCTAssertEqual(h.store.selection, .app("Sample Notes"), "the row before the last one")
        await h.store.removeApp("Sample Notes", deleteData: false)
        XCTAssertNil(h.store.selection, "no app is left: the empty state of the section")
        XCTAssertTrue(h.store.apps.isEmpty)
    }

    // An app that paddock removed (the CLI, another window) while it was
    // selected: the selection moves on too.
    func testARemovedEventMovesTheSelection() async throws {
        let h = try await Harness("library")
        let keys = h.store.apps.map(\.key)
        XCTAssertEqual(keys.first, "sample-notes")
        h.store.selection = .app("sample-notes")
        h.events.send(#"{"v":1,"kind":"session","app":"sample-notes","home":"default","state":"removed"}"#)
        await waitUntil { h.store.app(named: "sample-notes") == nil }
        XCTAssertEqual(h.store.selection, .app(keys[1]))
        XCTAssertNotNil(h.store.selectedApp)
    }

    // A failed remove keeps the app, the selection and the error.
    func testAFailedRemoveKeepsItsPlace() async throws {
        let h = try await Harness("ready")
        let line = "paddock: error: cannot remove Sample Mail: locked (os error 35)"
        h.runner.reset(prefix: "app remove")
        h.runner.on(prefix: "app remove", output: CommandOutput(status: 1, stdout: Data(), stderr: line + "\n"))
        h.store.selection = .app("Sample Mail")
        let text = await h.store.removeApp("Sample Mail", deleteData: false)
        XCTAssertNil(text)
        XCTAssertNotNil(h.store.app(named: "Sample Mail"))
        XCTAssertEqual(h.store.selection, .app("Sample Mail"))
        XCTAssertEqual(h.store.lastError?.title?.english, "Sample Mail was not removed")
        XCTAssertEqual(h.store.lastError?.details, line)
        XCTAssertEqual(h.store.lastError?.message, PlainError.generic)
    }

    // Start and Stop: a failure shows on the app, as a problem.
    func testAFailedStopShowsOnTheApp() async throws {
        let h = try await Harness("library")
        h.runner.reset(prefix: "app stop")
        h.runner.on(prefix: "app stop", output: CommandOutput(status: 1, stdout: Data(), stderr: "paddock: error: no session (os error 3)\n"))
        await h.store.stopApp("sample-notes")
        let error = try XCTUnwrap(h.store.appErrors["sample-notes"])
        XCTAssertEqual(error.title?.english, "Sample Notes did not stop")
        XCTAssertEqual(error.details, "paddock: error: no session (os error 3)")
        XCTAssertFalse(error.message?.english.contains("os error") ?? true)
        XCTAssertEqual(error.placement, .inPlace)
    }

    // The answers of Pause and Resume: a sentence, the line under Details.
    func testAFailedPauseSaysItPlainly() async throws {
        let h = try await Harness("building-v1")
        h.runner.reset(prefix: "macvm setup --pause-download")
        h.runner.on(prefix: "macvm setup --pause-download",
                    output: CommandOutput(status: 1, stdout: Data(), stderr: "paddock: error: no setup socket (os error 2)\n"))
        await h.store.requestPause()
        XCTAssertEqual(h.store.buildNote?.english,
                       "The build did not pause. paddock could not do this. Try again. The details say what paddock reported.")
        XCTAssertEqual(h.store.buildNoteDetails, "paddock: error: no setup socket (os error 2)")
        // A new try clears both.
        h.runner.reset(prefix: "macvm setup --pause-download")
        h.runner.on(prefix: "macvm setup --pause-download",
                    output: CommandOutput(status: 0, stdout: try Fixtures.data("pause-past-download.json"), stderr: ""))
        await h.store.requestPause()
        XCTAssertEqual(h.store.buildNote, LibraryCopy.pastDownload)
        XCTAssertNil(h.store.buildNoteDetails)
    }

    // MARK: Agents

    // Stop: the room says "Stopped". A run that ends by itself "Ended".
    func testAStoppedRunSaysStopped() async throws {
        let h = try await Harness("agents")
        var processes: [FakeAgentProcess] = []
        let agents = AgentStore(launcher: h.store, environment: ["SHELL": "/bin/zsh", "HOME": "/Users/demo"],
                                paddockPath: { "/opt/homebrew/bin/paddock" },
                                makeProcess: { _ in
                                    let process = FakeAgentProcess()
                                    processes.append(process)
                                    return process
                                })
        await agents.loadChoices()
        await agents.refreshRuns(force: true)

        // A pane of the launcher.
        let key = try XCTUnwrap(agents.start(AgentLaunch(harness: "codex", folder: "/Users/demo/new")))
        XCTAssertEqual(agents.room(key)?.stateWord.english, "Starting")
        await agents.stop(try XCTUnwrap(agents.room(key)))
        processes.first?.exit(143)
        let stopped = try XCTUnwrap(agents.room(key))
        XCTAssertEqual(stopped.state, .ended(done: false))
        XCTAssertTrue(stopped.stopped)
        XCTAssertEqual(stopped.stateWord.english, "Stopped")
        XCTAssertEqual(stopped.stateLine.english, "Stopped")
        XCTAssertTrue(AgentCopy.spoken(stopped).contains("Stopped"), AgentCopy.spoken(stopped))

        // A pane that ends by itself.
        let other = try XCTUnwrap(agents.start(AgentLaunch(harness: "gemini", folder: "/Users/demo/new")))
        processes.last?.exit(0)
        XCTAssertEqual(agents.room(other)?.stateWord.english, "Ended")
        XCTAssertFalse(agents.room(other)?.stopped ?? true)

        // A run that paddock lists: `paddock stop ID`, then it is remembered.
        let listed = try XCTUnwrap(agents.room("codex-4d5e6f"))
        XCTAssertFalse(listed.stopped)
        await agents.stop(listed)
        XCTAssertEqual(h.calls(["stop"]).last?.args, ["stop", "codex-4d5e6f"])
        XCTAssertTrue(agents.stoppedRuns.contains("codex-4d5e6f"))
        XCTAssertNil(agents.lastError)
    }

    // A Stop that fails: the room keeps its state and says why, plainly.
    func testAFailedStopOfARunSaysItPlainly() async throws {
        let h = try await Harness("agents")
        let agents = AgentStore(launcher: h.store, environment: [:], paddockPath: { "/opt/homebrew/bin/paddock" },
                                makeProcess: { _ in FakeAgentProcess() })
        await agents.loadChoices()
        await agents.refreshRuns(force: true)
        h.runner.reset(prefix: "stop")
        h.runner.on(prefix: "stop", output: CommandOutput(status: 1, stdout: Data(), stderr: "paddock: error: no such sandbox (os error 3)\n"))
        let room = try XCTUnwrap(agents.room("codex-4d5e6f"))
        let line = await agents.stop(room)
        XCTAssertEqual(line, "paddock: error: no such sandbox (os error 3)")
        XCTAssertEqual(agents.lastError?.english,
                       "Codex did not stop. paddock could not do this. Try again. The details say what paddock reported.")
        XCTAssertEqual(agents.lastErrorDetails, "paddock: error: no such sandbox (os error 3)")
        XCTAssertFalse(agents.stoppedRuns.contains("codex-4d5e6f"))
        XCTAssertFalse(try XCTUnwrap(agents.room("codex-4d5e6f")).stopped)
    }
}
