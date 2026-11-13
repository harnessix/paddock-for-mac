import Foundation
import Observation

/// The process of one terminal pane. The app runs it in a SwiftTerm view;
/// the tests use a fake. `onExit` comes on the main actor.
@MainActor
public protocol AgentProcess: AnyObject {
    func start(_ command: AgentCommand)
    /// Ends the process: SIGTERM, then SIGKILL if it stays.
    func terminate()
    var onExit: ((Int32?) -> Void)? { get set }
}

/// A terminal pane of the launcher window: a run that the launcher
/// started (`paddock run`), or a view of a run (`paddock view ID --write`).
public struct AgentPane: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case run(AgentLaunch)
        case view(runID: String)
    }

    public var id: String
    public var kind: Kind
    public var harness: String
    public var folder: String?
    public var started: Date
    /// The run paddock lists for this pane, once it is known.
    public var runID: String?
    public var running: Bool
    public var exitCode: Int32?
    public var ended: Date?
    /// True once you stopped the pane: its end is no failure.
    public var stopRequested = false

    /// The mode of a run that the launcher started. Nil for a view of a
    /// run: the pane does not know how that run started.
    public var mode: AgentMode? {
        if case .run(let launch) = kind { return launch.mode }
        return nil
    }

    /// True for a run that the launcher started in manual mode.
    public var isManual: Bool { mode == .manual }

    public init(id: String, kind: Kind, harness: String, folder: String?, started: Date, runID: String? = nil) {
        self.id = id
        self.kind = kind
        self.harness = harness
        self.folder = folder
        self.started = started
        self.runID = runID
        running = true
    }
}

/// One room of the Agents section: a run that paddock lists, a pane of
/// the launcher, or both.
public struct AgentRoom: Equatable, Sendable, Identifiable {
    /// The pane id for a pane, else the run id. It stays when the pane
    /// finds its run, so the selection stays too.
    public var key: String
    public var runID: String?
    public var paneID: String?
    public var harness: String
    public var title: String
    public var project: String?
    public var branch: String?
    public var started: Date?
    public var ended: Date?
    public var state: AgentState
    public var requests: [AgentRequestJSON]
    public var filesChanged: Int?
    public var files: [String]?
    public var activity: String?
    public var network: String?
    /// The pane runs `paddock run` or `paddock view` now.
    public var paneRunning: Bool
    /// How the agent works, when paddock or the pane says it. Nil for a
    /// run of a paddock with no `approvals` in `ps --json` that this
    /// launcher did not start.
    public var mode: AgentMode?
    /// True once you stopped the run from the launcher: the room then
    /// says "Stopped", not "Ended".
    public var stopped = false
    /// The run that spawned this one, when paddock says it.
    public var parent: String?
    /// paddock's notes of the run (`run_notes`). Nil with a paddock that
    /// does not give them: the Details tab then shows no notes.
    public var notes: [RunNote]?
    /// paddock's raw end line or board status: `blocked: no API key`.
    public var endReason: String?
    /// The exit code of the agent, from paddock or the pane.
    public var exitCode: Int?
    /// The questions of the agent in its mailbox that you did not read.
    /// Nil when this paddock does not say: the room has no mailbox.
    public var unreadAsks: Int?
    /// The commits of the loft. Nil: the room has no loft.
    public var loftCommits: Int?
    /// True when the loft got a commit since the read before: the
    /// character climbs up to write.
    public var loftWriting = false
    /// The device calls of the run that the event stream reported. Nil:
    /// no call so far, no cable.
    public var device: DeviceCalls?

    /// The state word of the room: `Stopped` after your Stop, else the
    /// word of the state.
    public var stateWord: UIText {
        if stopped, case .ended = state { return UIText("Stopped") }
        return state.word
    }

    /// The state line of the room, as the sidebar shows it.
    public var stateLine: UIText {
        if stopped, case .ended = state { return UIText("Stopped") }
        return state.line
    }

    /// True when the agent asks before each step (manual mode).
    public var manual: Bool { mode == .manual }
    /// True when the agent works on its own (full auto). The room and the
    /// detail show the "auto" tag.
    public var auto: Bool { mode == .auto }

    public var id: String { key }
    public var color: CharacterColor { AgentCharacter.color(harness) }

    public var projectName: String { projectText.english }

    /// The folder name of the project, or "no project" in the language
    /// of the interface.
    public var projectText: UIText {
        guard let project, !project.isEmpty else { return UIText("no project") }
        return UIText.verbatim((project as NSString).lastPathComponent)
    }

    /// The scene of the room: the tint of its place in the grid, the
    /// character of the harness, the pose of the state.
    public func scene(index: Int) -> RoomScene {
        let pose = state.pose
        var badge: Int?
        if case .waiting(let count) = state { badge = count }
        return RoomScene(tint: .at(index), color: color, pose: pose, badge: badge,
                         showsProgress: state == .starting)
    }

    /// Stop is there while the run lives or its pane runs.
    public var canStop: Bool { state.isLive || paneRunning }
}

/// The rooms from paddock's lists, the requests and the panes.
public enum AgentRooms {
    /// Ended runs stay in the section for a while, as on the board.
    public static let maxEnded = 12

    /// The facts of a newer paddock, by run id: the unread questions of
    /// the mailboxes, the runs whose loft just got a commit, the device
    /// calls. Each is empty with an older paddock.
    public struct Extras: Equatable, Sendable {
        public var unreadAsks: [String: Int]
        public var loftWriting: Set<String>
        public var devices: [String: DeviceCalls]

        public init(unreadAsks: [String: Int] = [:], loftWriting: Set<String> = [], devices: [String: DeviceCalls] = [:]) {
            self.unreadAsks = unreadAsks
            self.loftWriting = loftWriting
            self.devices = devices
        }

        public static let none = Extras()
    }

    public static func of(runs: [AgentRunJSON], ended: [EndedRunJSON], board: [String: BoardRunJSON],
                          requests: [AgentRequestJSON], panes: [AgentPane], titles: [String: String] = [:],
                          stopped: Set<String> = [], extras: Extras = .none) -> [AgentRoom] {
        var rooms: [AgentRoom] = []
        var used = Set<String>()
        let paneByRun = Dictionary(panes.compactMap { p in p.runID.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })

        func title(_ harness: String) -> String { AgentCharacter.title(harness, summary: titles[harness]) }

        for run in runs where !used.contains(run.id) {
            used.insert(run.id)
            let mine = requests.filter { $0.belongs(to: run.id) }
            let pane = paneByRun[run.id]
            rooms.append(AgentRoom(key: pane?.id ?? run.id, runID: run.id, paneID: pane?.id, harness: run.harness,
                                   title: title(run.harness), project: run.project ?? pane?.folder, branch: run.branch,
                                   started: run.started ?? pane?.started, ended: nil,
                                   state: AgentStateMapper.running(run, board: board[run.id], requests: mine.count),
                                   requests: mine, filesChanged: run.filesChanged, files: run.files,
                                   activity: run.activity, network: run.network, paneRunning: pane?.running ?? false,
                                   mode: run.approvals.flatMap(AgentMode.init(rawValue:)) ?? pane?.mode,
                                   parent: run.parent, notes: run.notes, endReason: board[run.id]?.status))
        }
        for run in ended.sorted(by: { ($0.ended ?? .distantPast) > ($1.ended ?? .distantPast) })
            where !used.contains(run.id) {
            used.insert(run.id)
            let pane = paneByRun[run.id]
            rooms.append(AgentRoom(key: pane?.id ?? run.id, runID: run.id, paneID: pane?.id, harness: run.harness,
                                   title: title(run.harness), project: run.project ?? pane?.folder, branch: run.branch,
                                   started: run.started ?? pane?.started, ended: run.ended ?? pane?.ended,
                                   state: AgentStateMapper.ended(run, board: board[run.id]), requests: [],
                                   filesChanged: nil, files: nil, activity: nil, network: nil,
                                   paneRunning: pane?.running ?? false, mode: pane?.mode,
                                   stopped: stopped.contains(run.id) || pane?.stopRequested == true,
                                   notes: run.notes, endReason: run.reason ?? board[run.id]?.status,
                                   exitCode: run.exitCode ?? pane?.exitCode.map(Int.init)))
        }
        // A pane whose run paddock does not list (yet, or any more).
        for pane in panes where pane.runID.map({ !used.contains($0) }) ?? true {
            var state = AgentStateMapper.pane(exit: pane.exitCode, running: pane.running, stopped: pane.stopRequested)
            // A view of a run that paddock no longer lists: the run ended.
            if case .view = pane.kind, !pane.running { state = .ended(done: false) }
            let mine = pane.runID.map { id in requests.filter { $0.belongs(to: id) } } ?? []
            if !mine.isEmpty { state = .waiting(mine.count) }
            rooms.append(AgentRoom(key: pane.id, runID: pane.runID, paneID: pane.id, harness: pane.harness,
                                   title: title(pane.harness), project: pane.folder, branch: nil,
                                   started: pane.started, ended: pane.ended, state: state, requests: mine,
                                   filesChanged: nil, files: nil, activity: nil, network: nil,
                                   paneRunning: pane.running, mode: pane.mode,
                                   stopped: pane.stopRequested || (pane.runID.map { stopped.contains($0) } ?? false),
                                   exitCode: pane.exitCode.map(Int.init)))
        }
        // The facts of a newer paddock, by the run of each room.
        for index in rooms.indices {
            guard let id = rooms[index].runID else { continue }
            rooms[index].unreadAsks = RunID.find(id, in: extras.unreadAsks)
            rooms[index].loftCommits = RunID.find(id, in: board)?.loftCommits
            rooms[index].loftWriting = extras.loftWriting.contains { RunID.same($0, id) }
            rooms[index].device = RunID.find(id, in: extras.devices)
        }
        // What needs you first; then the newest.
        let ordered = rooms.enumerated().sorted { a, b in
            if a.element.state.urgency != b.element.state.urgency { return a.element.state.urgency < b.element.state.urgency }
            let x = a.element.started ?? .distantPast
            let y = b.element.started ?? .distantPast
            if x != y { return x > y }
            return a.offset < b.offset
        }.map(\.element)
        var shownEnded = 0
        return ordered.filter { room in
            guard !room.state.isLive, !room.paneRunning, room.paneID == nil else { return true }
            shownEnded += 1
            return shownEnded <= maxEnded
        }
    }

    /// The live runs that the run of `room` spawned.
    public static func children(of room: AgentRoom, in rooms: [AgentRoom]) -> Int {
        guard let id = room.runID else { return 0 }
        return rooms.filter { $0.parent == id && $0.state.isLive }.count
    }

    /// The run of a pane: a run of the same harness in the same project
    /// (or the git root above it, or a worktree of it) that started at the
    /// pane's start or later. Runs that another pane has are skipped.
    public static func match(_ pane: AgentPane, runs: [AgentRunJSON], taken: Set<String>) -> String? {
        if case .view(let id) = pane.kind { return id }
        guard pane.runID == nil else { return pane.runID }
        let folder = pane.folder.map(AgentForm.normalize)
        let early = pane.started.addingTimeInterval(-10)
        let candidates = runs.filter { run in
            guard run.harness == pane.harness, !taken.contains(run.id) else { return false }
            if let started = run.started, started < early { return false }
            return true
        }
        let inFolder = candidates.filter { run in
            guard let folder, let project = run.project.map(AgentForm.normalize) else { return false }
            return project == folder || folder.hasPrefix(project + "/") || project.hasPrefix(folder + "/")
        }
        // The earliest start first: the pane started before the others.
        func earliest(_ list: [AgentRunJSON]) -> AgentRunJSON? {
            list.min { ($0.started ?? .distantFuture) < ($1.started ?? .distantFuture) }
        }
        if let run = earliest(inFolder) { return run.id }
        // A worktree run may name the worktree, not the folder: one new
        // run of the harness is that pane's.
        if candidates.count == 1, candidates[0].started != nil { return candidates[0].id }
        return nil
    }
}

/// A paddock command that this paddock does not have: the rooms show
/// "Needs a paddock with …" in its place.
public enum AgentGap: String, CaseIterable, Equatable, Sendable {
    case list, recent, ps, board

    public var command: String {
        switch self {
        case .list: return "paddock list --json"
        case .recent: return "paddock recent --json"
        case .ps: return "paddock ps --json"
        case .board: return "paddock board --json"
        }
    }

    public var line: UIText { AgentCopy.needs(command) }
}

/// The agent rooms: the harnesses, the recent projects, the runs that
/// paddock lists, the panes of this launcher and the requests.
///
/// paddock's event stream has no agent events, so the store reads
/// `ps --json`, `board --json` and `approvals --json` again every few
/// seconds: often while a run lives, seldom when none does. A stream that
/// starts or reports lost events triggers a read at once.
@MainActor
@Observable
public final class AgentStore {
    public var harnesses: [HarnessJSON] = []
    public var harnessesLoaded = false
    public var recents: [RecentProjectJSON] = []
    public var runs: [AgentRunJSON] = []
    public var ended: [EndedRunJSON] = []
    public var board: [String: BoardRunJSON] = [:]
    public var panes: [AgentPane] = []
    /// The commands that failed: the UI shows "Needs a paddock with …".
    public var gaps: Set<AgentGap> = []
    /// True once `ps --json` answered.
    public var runsLoaded = false
    /// True once `board --json` answered.
    public var boardLoaded = false
    /// A failed action, shown in place: Stop, Open in Terminal. A plain
    /// sentence; paddock's line is in `lastErrorDetails`.
    public var lastError: UIText?
    /// paddock's own line behind `lastError`, for its "Details".
    public var lastErrorDetails: String?
    /// The runs that you stopped from the launcher: their rooms say
    /// "Stopped".
    public var stoppedRuns: Set<String> = []
    /// The unread questions of each mailbox (`unread_ask` of `paddock mail
    /// ls --json`). Empty with a paddock that does not give the field.
    public var unreadAsks: [String: Int] = [:]
    /// The runs whose loft got a commit between the last two board reads.
    public var loftWriting: Set<String> = []
    /// The device calls of each run, from the event stream.
    public var deviceCalls: [String: DeviceCalls] = [:]

    @ObservationIgnored public let launcher: LauncherStore
    @ObservationIgnored public var makeProcess: (AgentPane) -> AgentProcess
    @ObservationIgnored public var processes: [String: AgentProcess] = [:]
    /// The path of the paddock binary for the panes.
    @ObservationIgnored public var paddockPath: () -> String?
    /// The environment of the panes: the PATH of the user's shell and the
    /// needed set (`LauncherEnvironment.variables`).
    @ObservationIgnored public var environment: [String: String]
    /// True: a pane starts paddock through the user's login shell. False:
    /// it starts paddock itself, because `environment` already comes from
    /// that shell.
    @ObservationIgnored public var paneThroughShell = true
    /// Where the environment of the paddock calls comes from. Check this
    /// Mac shows one line when the shell did not answer.
    public var environmentSource: LauncherEnvironment.Source = .inherited
    /// Called with the agent names of `paddock list --json`. True when
    /// the PATH of the paddock calls changed by them (the fallback PATH
    /// got the folder of a new agent): the list is read once more.
    @ObservationIgnored public var agentsListed: (([String]) -> Bool)?
    @ObservationIgnored var pollTask: Task<Void, Never>?
    @ObservationIgnored var gate = StatusGate()
    @ObservationIgnored var paneSerial = 0
    /// The seconds between two reads while a run lives, and else.
    @ObservationIgnored public var liveInterval: Double = 3
    @ObservationIgnored public var quietInterval: Double = 10
    /// Called when a pane goes, so the app can drop its terminal view.
    @ObservationIgnored public var paneClosed: ((String) -> Void)?
    /// The seconds after a terminate before a kill.
    @ObservationIgnored public var killAfter: Double = 5
    /// The flag of manual mode for this paddock: `--manual` or `--no-yolo`
    /// (`AgentMode.manualFlag`), from `paddock run --help`.
    public var manualFlag = "--no-yolo"

    public init(launcher: LauncherStore, environment: [String: String] = ProcessInfo.processInfo.environment,
                paddockPath: @escaping () -> String? = { nil },
                makeProcess: @escaping (AgentPane) -> AgentProcess) {
        self.launcher = launcher
        self.environment = environment
        self.paddockPath = paddockPath
        self.makeProcess = makeProcess
    }

    /// Takes the environment of the paddock calls for the panes too.
    public func use(_ environment: LauncherEnvironment) {
        self.environment = environment.variables
        paneThroughShell = !environment.isFromShell
        if environmentSource != environment.source { environmentSource = environment.source }
    }

    /// True when the shell did not answer and the usual folders are the PATH.
    public var usesFallbackPath: Bool {
        if case .fallback = environmentSource { return true }
        return false
    }

    /// The command of a pane: paddock with `args`.
    func paneCommand(_ paddock: String, args: [String], directory: String?) -> AgentCommand {
        paneThroughShell
            ? AgentCommand.paddock(paddock, args: args, directory: directory, environment: environment)
            : AgentCommand.direct(paddock, args: args, directory: directory, environment: environment)
    }

    // MARK: Rooms

    public var rooms: [AgentRoom] {
        let titles = Dictionary(harnesses.map { ($0.name, $0.summary ?? $0.name) }, uniquingKeysWith: { a, _ in a })
        return AgentRooms.of(runs: runs, ended: ended, board: board, requests: launcher.agentRequests,
                             panes: panes, titles: titles, stopped: stoppedRuns,
                             extras: AgentRooms.Extras(unreadAsks: unreadAsks, loftWriting: loftWriting,
                                                       devices: deviceCalls))
    }

    public func room(_ key: String) -> AgentRoom? { rooms.first { $0.key == key } }

    public var liveRooms: [AgentRoom] { rooms.filter { $0.state.isLive || $0.paneRunning } }

    /// The harnesses that are terminal agents, for the sheet.
    public var agentHarnesses: [HarnessJSON] { harnesses.filter { !$0.app } }

    // MARK: Reads

    /// Reads the harnesses and the recent projects: at start and when the
    /// New Agent sheet opens.
    public func loadChoices() async {
        guard let service = launcher.service else { return }
        do {
            var listed = try await AgentStore.list(service)
            // The fallback PATH has a folder for each agent that paddock
            // knows. A name that is new to the launcher widens it, and
            // paddock looks once more with the wider PATH.
            if agentsListed?(listed.filter { !$0.app }.map(\.name)) == true,
               let again = try? await AgentStore.list(service) {
                listed = again
            }
            harnesses = listed
            gaps.remove(.list)
        } catch {
            if !harnessesLoaded { gaps.insert(.list) }
        }
        harnessesLoaded = true
        // paddock run --help names --manual once paddock has it, as
        // `app --help` names suspend.
        let help = try? await service.raw(AgentArgs.runHelp)
        manualFlag = AgentMode.manualFlag(runHelp: help.flatMap { $0.status == 0 ? $0.stdoutText : nil })
        do {
            let out = try await service.raw(AgentArgs.recent)
            guard out.status == 0 else { throw CommandError.failed(status: out.status, line: "") }
            recents = try RecentProjectJSON.list(out.stdout)
            gaps.remove(.recent)
        } catch {
            if recents.isEmpty { gaps.insert(.recent) }
        }
    }

    /// One `paddock list --json`.
    static func list(_ service: PaddockService) async throws -> [HarnessJSON] {
        let out = try await service.raw(AgentArgs.list)
        guard out.status == 0 else { throw CommandError.failed(status: out.status, line: CLIPaddockService.lastLine(out.stderr)) }
        return try HarnessJSON.list(out.stdout)
    }

    /// Reads the runs (`ps`) and their board states, at most once every
    /// `StatusGate.interval` unless `force`.
    public func refreshRuns(force: Bool = false) async {
        guard let service = launcher.service else { return }
        if force { gate.reset() }
        let now = launcher.clock.now()
        if gate.allow("ps", now: now) {
            do {
                let out = try await service.raw(AgentArgs.ps)
                guard out.status == 0 else { throw CommandError.failed(status: out.status, line: "") }
                let ps = try PsJSON.decode(out.stdout)
                // App sandboxes of `paddock app` are not agent rooms. A
                // harness the list does not name may be an agent: it stays.
                let apps = Set(harnesses.filter(\.app).map(\.name))
                runs = ps.sandboxes.filter { !apps.contains($0.harness) }
                ended = ps.ended.filter { !apps.contains($0.harness) }
                runsLoaded = true
                gaps.remove(.ps)
                bindPanes()
            } catch {
                // A paddock that answered before keeps its runs: one
                // failed read is not a missing command.
                if !runsLoaded { gaps.insert(.ps) }
            }
        }
        if gate.allow("board", now: now) {
            do {
                let out = try await service.raw(AgentArgs.board)
                guard out.status == 0 else { throw CommandError.failed(status: out.status, line: "") }
                let next = try BoardJSON.decode(out.stdout).runs
                // A loft with more commits than at the read before: the
                // agent wrote a note there. The first read only counts.
                let writing = boardLoaded ? Set(next.compactMap { id, run -> String? in
                    guard let now = run.loftCommits, let before = board[id]?.loftCommits, now > before else { return nil }
                    return id
                }) : []
                if writing != loftWriting { loftWriting = writing }
                board = next
                boardLoaded = true
                gaps.remove(.board)
            } catch {
                if !boardLoaded { gaps.insert(.board) }
            }
        }
        if gate.allow("mail", now: now) {
            // An older paddock has no `mail ls --json`, or no `unread_ask`:
            // the rooms then have no mailbox. It is no gap of the page.
            if let out = try? await service.raw(AgentArgs.mail), out.status == 0,
               let asks = try? MailboxJSON.unreadAsks(out.stdout) {
                if asks != unreadAsks { unreadAsks = asks }
            }
        }
    }

    /// Gives each pane its run, once paddock lists it.
    func bindPanes() {
        var taken = Set(panes.compactMap(\.runID))
        for index in panes.indices where panes[index].runID == nil {
            if let id = AgentRooms.match(panes[index], runs: runs, taken: taken) {
                panes[index].runID = id
                taken.insert(id)
            }
        }
    }

    /// Starts the reads: now, then on a timer. A new start replaces the
    /// old timer.
    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.loadChoices()
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let seconds = self.liveRooms.isEmpty ? self.quietInterval : self.liveInterval
                try? await self.launcher.clock.sleep(seconds: seconds)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One read of the runs, and of the requests while a run lives: the
    /// event stream brings the app questions, but no agent cards. Without
    /// a live run the launcher does not poll the approvals.
    public func tick() async {
        await refreshRuns()
        if !liveRooms.isEmpty { await launcher.reloadApprovals() }
    }

    /// An event of paddock's stream: a stream that starts, or that lost
    /// events, reads the runs again at once.
    public func apply(_ event: PaddockEvent) {
        switch event {
        case .stream:
            Task { await self.refreshRuns(force: true) }
        case .deviceCall(let call):
            // One more spark on the cable of the run.
            var calls = deviceCalls[call.run] ?? DeviceCalls()
            calls.calls += 1
            calls.covered = call.covered
            calls.device = call.device ?? calls.device
            deviceCalls[call.run] = calls
        default:
            break
        }
    }

    // MARK: Panes

    /// Starts a run in a new pane and returns the key of its room. Nil
    /// when no checked paddock is there.
    @discardableResult
    public func start(_ launch: AgentLaunch) -> String? {
        guard launcher.service != nil, let paddock = paddockPath() else {
            lastError = LibraryCopy.offline
            lastErrorDetails = nil
            return nil
        }
        let pane = newPane(.run(launch), harness: launch.harness, folder: launch.folder)
        let command = paneCommand(paddock, args: launch.args(manualFlag: manualFlag), directory: launch.folder)
        run(pane, command)
        return pane.id
    }

    /// Start Again of a failed run: the same start in a new pane, for a run
    /// that this launcher started. Returns the key of the new room, or nil
    /// when the launcher does not know the start: the New Agent sheet then
    /// opens for the project.
    @discardableResult
    public func startAgain(_ room: AgentRoom) -> String? {
        guard let paneID = room.paneID, let pane = panes.first(where: { $0.id == paneID }),
              case .run(let launch) = pane.kind else { return nil }
        return start(launch)
    }

    /// Reopen: a pane with `paddock view ID --write` for a run.
    @discardableResult
    public func reopen(_ room: AgentRoom) -> String? {
        guard let id = room.runID, let paddock = paddockPath(), launcher.service != nil else { return nil }
        // One view per run: an old pane of the run that ended goes.
        if let old = panes.first(where: { $0.runID == id && !$0.running }) { close(old.id) }
        let pane = newPane(.view(runID: id), harness: room.harness, folder: room.project, runID: id)
        let command = paneCommand(paddock, args: AgentArgs.view(id), directory: nil)
        run(pane, command)
        return pane.id
    }

    func newPane(_ kind: AgentPane.Kind, harness: String, folder: String?, runID: String? = nil) -> AgentPane {
        paneSerial += 1
        let pane = AgentPane(id: "pane-\(paneSerial)-\(UUID().uuidString.prefix(8).lowercased())", kind: kind,
                             harness: harness, folder: folder, started: launcher.clock.now(), runID: runID)
        panes.append(pane)
        return pane
    }

    func run(_ pane: AgentPane, _ command: AgentCommand) {
        let process = makeProcess(pane)
        processes[pane.id] = process
        let id = pane.id
        process.onExit = { [weak self] code in
            self?.paneExited(id, code: code)
        }
        process.start(command)
        Task { await self.refreshRuns(force: true) }
    }

    func paneExited(_ id: String, code: Int32?) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        panes[index].running = false
        panes[index].exitCode = code
        panes[index].ended = launcher.clock.now()
        Task { await self.refreshRuns(force: true) }
    }

    /// Removes an ended pane and its process.
    public func close(_ paneID: String) {
        if let process = processes[paneID], panes.first(where: { $0.id == paneID })?.running == true {
            process.terminate()
        }
        processes[paneID] = nil
        panes.removeAll { $0.id == paneID }
        paneClosed?(paneID)
    }

    // MARK: Actions

    /// Stop: `paddock stop ID` for a run that paddock lists; a pane whose
    /// run is not listed yet ends its process. Returns paddock's line on a
    /// failure.
    @discardableResult
    public func stop(_ room: AgentRoom) async -> String? {
        lastError = nil
        lastErrorDetails = nil
        if let id = room.runID, room.state.isLive {
            guard let service = launcher.service else {
                lastError = LibraryCopy.offline
                return UIText("paddock is not reachable").english
            }
            do {
                try await service.execute(AgentArgs.stop(id))
            } catch {
                // The room keeps its state and says why, in plain words.
                let line = LauncherStore.line(of: error)
                let problem = PlainError.problem(line)
                lastError = UIText("%@ did not stop. %@", room.title, problem.message)
                lastErrorDetails = problem.details
                return line
            }
            stoppedRuns.insert(id)
            await refreshRuns(force: true)
            return nil
        }
        if let paneID = room.paneID, let process = processes[paneID] {
            if let index = panes.firstIndex(where: { $0.id == paneID }) { panes[index].stopRequested = true }
            process.terminate()
            let after = killAfter
            Task { [weak self] in
                try? await self?.launcher.clock.sleep(seconds: after)
                guard let self, self.panes.first(where: { $0.id == paneID })?.running == true else { return }
                self.processes[paneID]?.terminate()
            }
            return nil
        }
        return nil
    }

    /// Answers an agent request: No, Yes once, Yes for this session.
    @discardableResult
    public func answer(_ request: AgentRequestJSON, _ answer: AgentAnswer) async -> String? {
        guard let service = launcher.service else { return UIText("paddock is not reachable").english }
        if answer == .session, !request.sessionAllowed { return UIText("This request cannot be allowed for the session.").english }
        do {
            try await service.execute(AgentArgs.answer(request.id, answer))
        } catch {
            return LauncherStore.line(of: error)
        }
        launcher.answeredRequestIDs.insert(request.id)
        launcher.agentRequests.removeAll { $0.id == request.id }
        launcher.dismissNotice(AgentNotice.requestPrefix + request.id)
        return nil
    }

    /// The run of "Open in Terminal" and the detail's Reopen.
    public func viewArgs(_ room: AgentRoom) -> [String]? {
        room.runID.map(AgentArgs.view)
    }
}
