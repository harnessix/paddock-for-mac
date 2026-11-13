import XCTest
@testable import PaddockKit

/// The facts of a newer paddock on the agent pages: the failure card of a
/// failed run, the notes of a run (`run_notes`), the mailbox
/// (`unread_ask`), the loft (`loft_commits`) and the device calls
/// (`device_call`). Fixtures/agents-024 has them all; Fixtures/agents is
/// paddock 0.2.3 with none of them.
@MainActor
final class AgentFactsTests: XCTestCase {
    func make(_ scenario: String) async throws -> (Harness, AgentStore) {
        let h = try await Harness(scenario)
        let agents = AgentStore(launcher: h.store, environment: ["SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin"],
                                paddockPath: { "/opt/homebrew/bin/paddock" }, makeProcess: { _ in FakeAgentProcess() })
        await agents.loadChoices()
        await agents.refreshRuns(force: true)
        return (h, agents)
    }

    func room(_ state: AgentState, endReason: String? = nil, exitCode: Int? = nil, notes: [RunNote]? = nil) -> AgentRoom {
        AgentRoom(key: "run-1", runID: "run-1", paneID: nil, harness: "claude", title: "Claude Code",
                  project: "/Users/demo/src/shop", branch: nil, started: nil, ended: nil, state: state, requests: [],
                  filesChanged: nil, files: nil, activity: nil, network: nil, paneRunning: false,
                  notes: notes, endReason: endReason, exitCode: exitCode)
    }

    // MARK: The failure card

    // Each known line of paddock gets its own words and next step.
    func testKnownFailureLinesGetPlainWords() {
        let cases: [(String, AgentFailure.Kind)] = [
            ("paddock: error: claude is not installed or not on PATH", .agentMissing),
            ("zsh: command not found: codex", .agentMissing),
            ("blocked: no API key", .notLoggedIn),
            ("Please log in with /login", .notLoggedIn),
            ("paddock: error: /Users/demo/notes is not a git repository", .notGitRepository),
            ("--worktree needs at least one commit", .notGitRepository),
            ("paddock: claude already runs in /Users/demo/src/shop", .alreadyRuns),
            ("No space left on device (os error 28)", .noSpace),
            ("paddock: error: cannot start the sandbox: bwrap: setting up uid map", .sandbox),
            ("paddock-vm is not installed next to paddock. Install paddock again with Homebrew.", .sandbox),
            ("error: unexpected argument '--manual' found", .oldPaddock),
            ("error: unrecognized subcommand 'run'", .oldPaddock),
            ("curl: (6) Could not resolve host: api.anthropic.com", .noNetwork),
        ]
        for (line, kind) in cases {
            XCTAssertEqual(AgentFailure.kind(of: line), kind, line)
        }
        XCTAssertNil(AgentFailure.kind(of: "the sandbox exited with a status of the backend: 0x7f3a"))
        XCTAssertNil(AgentFailure.kind(of: ""))
    }

    // The card says what failed in the launcher's words and keeps
    // paddock's line for the disclosure. An unknown line is never the
    // message: the card has the general words, the line goes under Details.
    func testTheCardNeverShowsTheRawLineAsItsMessage() {
        let known = try! XCTUnwrap(AgentFailure.of(room(.failed("no API key"), endReason: "blocked: no API key", exitCode: 1)))
        XCTAssertEqual(known.kind, .notLoggedIn)
        XCTAssertEqual(known.line, "blocked: no API key")
        XCTAssertEqual(known.exitCode, 1)
        XCTAssertEqual(known.steps, [.startAgain, .openLog])

        let raw = "Error: ENOTSUP 0x7f3a at frame 12"
        let unknown = try! XCTUnwrap(AgentFailure.of(room(.failed(raw), endReason: raw, exitCode: 2)))
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(unknown.line, raw)
        XCTAssertNotEqual(unknown.message.english, raw)
        XCTAssertFalse(unknown.message.english.contains("0x7f3a"))
        XCTAssertFalse(unknown.next.english.contains("0x7f3a"))
        XCTAssertEqual(unknown.steps.first, .openLog)

        // A `blocked:` status that the launcher does not know: the agent
        // is blocked, its words go under Details.
        let blocked = try! XCTUnwrap(AgentFailure.of(room(.failed("waiting for the design"),
                                                          endReason: "blocked: waiting for the design")))
        XCTAssertEqual(blocked.kind, .blocked)
        XCTAssertEqual(blocked.line, "blocked: waiting for the design")

        // A run that did not fail has no card.
        XCTAssertNil(AgentFailure.of(room(.working)))
        XCTAssertNil(AgentFailure.of(room(.ended(done: false), exitCode: 0)))
    }

    // Each kind has its words, a next step and at least one button; the
    // buttons are the four of the card.
    func testEveryKindHasWordsAndSteps() {
        for kind in AgentFailure.Kind.allCases {
            let failure = AgentFailure(kind: kind)
            XCTAssertFalse(failure.message.english.isEmpty, "\(kind)")
            XCTAssertFalse(failure.next.english.isEmpty, "\(kind)")
            XCTAssertFalse(failure.steps.isEmpty, "\(kind)")
            XCTAssertEqual(Set(failure.steps).count, failure.steps.count, "\(kind): a button twice")
        }
        XCTAssertEqual(AgentFailure(kind: .oldPaddock).steps.first, .updatePaddock)
        XCTAssertEqual(AgentFailure(kind: .alreadyRuns).steps.first, .showAgents)
        XCTAssertEqual(AgentFailure.updateCommand, "brew upgrade paddock")
    }

    // With no line, the exit code tells a signal; an error note or the
    // screen of the pane names the cause.
    func testExitCodesNotesAndTheScreen() {
        XCTAssertEqual(AgentFailure.of(room(.failed(nil), exitCode: 137))?.kind, .killed)
        XCTAssertEqual(AgentFailure.of(room(.failed(nil), exitCode: 143))?.kind, .interrupted)
        XCTAssertEqual(AgentFailure.of(room(.failed(nil), exitCode: 1))?.kind, .unknown)
        XCTAssertNil(AgentFailure.of(room(.failed(nil), exitCode: 1))?.line)

        let notes = [RunNote(level: .info, text: "paddock: starting"),
                     RunNote(level: .error, text: "paddock: error: codex is not installed")]
        let noted = AgentFailure.of(room(.failed(nil), exitCode: 1, notes: notes))
        XCTAssertEqual(noted?.kind, .agentMissing)
        XCTAssertEqual(noted?.line, "paddock: error: codex is not installed")

        let screen = """
        paddock: starting claude in /Users/demo/src/shop (network api)
        paddock: error: cannot start the sandbox: the VM did not start

        """
        XCTAssertEqual(AgentFailure.line(fromScreen: screen), "paddock: error: cannot start the sandbox: the VM did not start")
        XCTAssertEqual(AgentFailure.of(room(.failed(nil), exitCode: 1), screen: screen)?.kind, .sandbox)
        XCTAssertEqual(AgentFailure.line(fromScreen: "paddock: starting claude\nbye\n"), "paddock: starting claude")
        XCTAssertNil(AgentFailure.line(fromScreen: "\n\n"))
    }

    // The rooms of paddock 0.2.4: the failed runs carry their line, their
    // exit code and their notes to the card.
    func testFailedRunsOfTheFixtureGetTheirCards() async throws {
        let (_, agents) = try await make("agents-024")
        let grok = try XCTUnwrap(agents.rooms.first { $0.runID == "grok-222222" })
        XCTAssertEqual(AgentFailure.of(grok)?.kind, .notLoggedIn)
        let gemini = try XCTUnwrap(agents.rooms.first { $0.runID == "gemini-333333" })
        let unknown = try XCTUnwrap(AgentFailure.of(gemini))
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(unknown.line, "paddock: error: the sandbox exited with a status of the backend: 0x7f3a")
        XCTAssertEqual(unknown.exitCode, 2)
        let opencode = try XCTUnwrap(agents.rooms.first { $0.runID == "opencode-444444" })
        XCTAssertEqual(AgentFailure.of(opencode)?.kind, .oldPaddock)
    }

    // Start Again starts the same launch in a new pane; a run that this
    // launcher did not start has no launch to repeat.
    func testStartAgainRepeatsTheLaunch() async throws {
        let (_, agents) = try await make("agents")
        let launch = AgentLaunch(harness: "claude", folder: "/Users/demo/src/notes", network: .api, worktree: false, mode: .manual)
        let key = try XCTUnwrap(agents.start(launch))
        let pane = try XCTUnwrap(agents.panes.first { $0.id == key })
        agents.paneExited(pane.id, code: 1)
        let failed = try XCTUnwrap(agents.room(key))
        XCTAssertEqual(failed.state, .failed(nil))
        XCTAssertEqual(failed.exitCode, 1)
        let again = try XCTUnwrap(agents.startAgain(failed))
        XCTAssertNotEqual(again, key)
        XCTAssertEqual(agents.panes.first { $0.id == again }?.kind, .run(launch))
        XCTAssertNotNil(agents.room(key), "the failed pane stays, with its screen")

        let listed = try XCTUnwrap(agents.rooms.first { $0.runID == "grok-222222" })
        XCTAssertNil(agents.startAgain(listed))
    }

    // MARK: The notes of a run

    func testRunNotesAreGroupedByLevel() throws {
        let ps = try PsJSON.decode(Fixtures.data("ps-agents-024.json"))
        let claude = try XCTUnwrap(ps.sandboxes.first { $0.id == "claude-1a2b3c" })
        let notes = try XCTUnwrap(claude.notes)
        XCTAssertEqual(notes.count, 4)
        let groups = RunNotes.grouped(notes)
        XCTAssertEqual(groups.map(\.level), [.ask, .warning, .info])
        XCTAssertEqual(groups.last?.notes.map(\.text), ["paddock: starting claude in /Users/demo/src/shop (network api)",
                                                       "paddock: worktree paddock/claude-1a2b3c"])
        // An empty list is a paddock that has the field and no note.
        XCTAssertEqual(ps.sandboxes.first { $0.id == "codex-4d5e6f" }?.notes, [])
        XCTAssertEqual(ps.ended.first { $0.id == "grok-222222" }?.notes?.first?.level, .error)

        // paddock 0.2.3: no field, no notes, no group.
        let old = try PsJSON.decode(Fixtures.data("ps-agents.json"))
        XCTAssertTrue(old.sandboxes.allSatisfy { $0.notes == nil })
        XCTAssertTrue(old.ended.allSatisfy { $0.notes == nil })
        XCTAssertEqual(RunNotes.grouped(nil), [])

        // Unknown levels are plain notes; a note with no words goes.
        let odd = RunNote.list(.array([.object(["level": .string("trace"), "text": .string("x")]),
                                       .object(["level": .string("error"), "text": .string("  ")]),
                                       .string("plain")]))
        XCTAssertEqual(odd, [RunNote(level: .info, text: "x"), RunNote(level: .info, text: "plain")])
        XCTAssertNil(RunNote.list(.string("not a list")))
        for level in RunNote.Level.allCases {
            XCTAssertFalse(level.title.english.isEmpty)
            XCTAssertFalse(level.symbol.name.isEmpty)
        }
    }

    func testRoomsCarryTheNotes() async throws {
        let (_, new) = try await make("agents-024")
        XCTAssertEqual(new.rooms.first { $0.runID == "claude-1a2b3c" }?.notes?.count, 4)
        let (_, old) = try await make("agents")
        XCTAssertTrue(old.rooms.allSatisfy { $0.notes == nil })
    }

    // MARK: The motions

    // The mailbox hops for an unread question; a mailbox with none shows
    // its flag down. paddock 0.2.3 gives no `unread_ask`: no mailbox.
    func testMailboxFromUnreadAsks() async throws {
        XCTAssertEqual(try MailboxJSON.unreadAsks(Fixtures.data("mail-ls-024.json")),
                       ["claude-1a2b3c": 1, "codex-4d5e6f": 0])
        XCTAssertEqual(try MailboxJSON.unreadAsks(Fixtures.data("mail-ls-023.json")), [:])
        XCTAssertEqual(try MailboxJSON.unreadAsks(Data("[]".utf8)), [:])
        XCTAssertEqual(try MailboxJSON.unreadAsks(Data(#"{"runs":[{"id":"a1b2c3","unread_ask":2}]}"#.utf8)), ["a1b2c3": 2])
        XCTAssertThrowsError(try MailboxJSON.unreadAsks(Data(#"{"api_version":"paddock.other/v1"}"#.utf8)))

        let (h, agents) = try await make("agents-024")
        XCTAssertEqual(h.calls(AgentArgs.mail).count, 1)
        let claude = try XCTUnwrap(agents.rooms.first { $0.runID == "claude-1a2b3c" })
        XCTAssertEqual(claude.unreadAsks, 1)
        XCTAssertEqual(RoomWorld.of(claude).mail, .question)
        XCTAssertEqual(RoomWorld.of(try XCTUnwrap(agents.rooms.first { $0.runID == "codex-4d5e6f" })).mail, .empty)

        // The hop runs once when the question comes.
        var track = RoomMotionTrack(world: RoomWorld(mail: .empty), pose: .work)
        let now = ISO.date("2026-11-06T10:00:00Z")
        track.set(RoomWorld.of(claude), pose: .work, at: now, mode: .full)
        XCTAssertGreaterThan(track.frame(at: now.addingTimeInterval(WorldMotion.boxHop.duration / 2)).hop, 0)
    }

    // A loft commit since the read before sends the character up; the
    // next read without one brings it down. The first read only counts.
    func testLoftClimbsOnANewCommit() async throws {
        let board = try BoardJSON.decode(Fixtures.data("board-agents-024.json"))
        XCTAssertEqual(board.runs["claude-1a2b3c"]?.loftCommits, 2, "the run's own count wins")
        XCTAssertEqual(board.runs["codex-4d5e6f"]?.loftCommits, 7, "else the count of its project")
        XCTAssertTrue(try BoardJSON.decode(Fixtures.data("board-agents.json")).runs.values.allSatisfy { $0.loftCommits == nil })

        let (_, agents) = try await make("agents-024")
        var claude = try XCTUnwrap(agents.rooms.first { $0.runID == "claude-1a2b3c" })
        XCTAssertEqual(claude.loftCommits, 2)
        XCTAssertFalse(claude.loftWriting)
        XCTAssertEqual(RoomWorld.of(claude).loft, RoomWorld.Loft(notebooks: 2, writing: false))

        await agents.refreshRuns(force: true)
        claude = try XCTUnwrap(agents.rooms.first { $0.runID == "claude-1a2b3c" })
        XCTAssertEqual(claude.loftCommits, 3)
        XCTAssertTrue(claude.loftWriting)
        XCTAssertEqual(RoomWorld.of(claude).loft, RoomWorld.Loft(notebooks: 3, writing: true))
        // The fixture's run has a request: it waits at the door, the
        // request wins over the loft. Without one it goes up.
        XCTAssertNotNil(RoomWorld.of(claude).request)
        XCTAssertFalse(RoomWorld.of(claude).characterInLoft)
        var free = claude
        free.state = .working
        free.requests = []
        XCTAssertTrue(RoomWorld.of(free).characterInLoft)
        XCTAssertFalse(try XCTUnwrap(agents.rooms.first { $0.runID == "codex-4d5e6f" }).loftWriting)

        await agents.refreshRuns(force: true)
        claude = try XCTUnwrap(agents.rooms.first { $0.runID == "claude-1a2b3c" })
        XCTAssertFalse(claude.loftWriting, "no new commit: the character comes down")
    }

    // Each device_call event sends one spark on the cable of its run; a
    // covered socket raises the card.
    func testDeviceCallsSendSparks() async throws {
        let (_, agents) = try await make("agents-024")
        let first = try XCTUnwrap(agents.rooms.first { $0.runID == "claude-1a2b3c" })
        XCTAssertNil(first.device)
        XCTAssertNil(RoomWorld.of(first).device)
        for line in try Fixtures.stream("events-device-call.jsonl") {
            if let event = PaddockEvent.decode(line: line), case .deviceCall = event { agents.apply(event) }
        }
        let room = try XCTUnwrap(agents.rooms.first { $0.runID == "claude-1a2b3c" })
        XCTAssertEqual(room.device, DeviceCalls(calls: 2, covered: true, device: "camera"))
        XCTAssertEqual(RoomWorld.of(room).device, RoomWorld.Device(calls: 2, covered: true))
        XCTAssertNil(agents.rooms.first { $0.runID == "codex-4d5e6f" }?.device)

        XCTAssertEqual(PaddockEvent.decode(line: #"{"v":1,"kind":"device_call","run":"a1b2c3","device":"gpu"}"#),
                       .deviceCall(DeviceCallEvent(run: "a1b2c3", device: "gpu", covered: false)))
        // A call that names no run is no spark.
        XCTAssertEqual(PaddockEvent.decode(line: #"{"v":1,"kind":"device_call","device":"gpu"}"#), .unknown(kind: "device_call"))
    }

    // paddock 0.2.3 has none of the fields: no mailbox, no loft, no
    // cable, the plain room, and the reads go on.
    func testAnOlderPaddockShowsNoMotion() async throws {
        let (h, agents) = try await make("agents")
        XCTAssertFalse(agents.rooms.isEmpty)
        XCTAssertFalse(agents.gaps.contains(.ps))
        XCTAssertFalse(agents.gaps.contains(.board))
        XCTAssertEqual(h.calls(AgentArgs.mail).count, 1, "asked once; the fake has no answer")
        XCTAssertEqual(agents.unreadAsks, [:])
        for room in agents.rooms {
            let world = RoomWorld.of(room)
            XCTAssertNil(world.mail, room.key)
            XCTAssertNil(world.loft, room.key)
            XCTAssertNil(world.device, room.key)
        }
        await agents.refreshRuns(force: true)
        XCTAssertTrue(agents.loftWriting.isEmpty)
    }
}
