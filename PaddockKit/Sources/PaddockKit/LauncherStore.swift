import Foundation
import Observation

/// The sidebar items of the main window.
public enum SidebarItem: Hashable, Sendable {
    case app(String)
    case questions
    case baseImage
    /// The Agents section with no run chosen: the grid of agent rooms.
    case agents
    /// One agent room, by `AgentRoom.key`.
    case agent(String)

    /// True for the Agents section and its rooms: ⌘N starts an agent there.
    public var isAgents: Bool {
        switch self {
        case .agents, .agent: return true
        default: return false
        }
    }
}

public enum DetailTab: String, Hashable, Sendable, CaseIterable {
    case overview, grants, log
}

/// A short line at the bottom of a window that goes away by itself.
public struct Toast: Equatable, Sendable, Identifiable {
    public var text: UIText
    public var id: UUID

    public init(_ text: UIText) {
        self.text = text
        self.id = UUID()
    }
}

/// Where the paddock binary stands.
public enum BinaryState: Equatable, Sendable {
    case checking
    case missing
    case found(path: String, verdict: VersionGate.Verdict)

    public var isUsable: Bool {
        if case .found(_, .ok) = self { return true }
        return false
    }
}

/// Allows one status call per key every 5 seconds. With a healthy event
/// stream the launcher never polls faster than that.
public struct StatusGate: Sendable {
    public static let interval: TimeInterval = 5
    private var last: [String: Date] = [:]

    public init() {}

    public mutating func allow(_ key: String, now: Date) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < StatusGate.interval { return false }
        last[key] = now
        return true
    }

    public mutating func reset() { last = [:] }
    public mutating func reset(_ key: String) { last[key] = nil }
}

/// The root state of the launcher. Backend truth comes from paddock: the
/// store reads snapshots once, then follows the event stream.
@MainActor
@Observable
public final class LauncherStore {
    // MARK: Backend state
    public var binary: BinaryState = .checking
    public var golden: GoldenState = .none
    public var goldenLoaded = false
    public var disk: DiskJSON?
    public var logDir: String?
    public var goldenLogPath: String?
    public var apps: [AppItem] = []
    public var questions: [QuestionJSON] = []
    /// The requests of terminal agents that wait for an answer, from the
    /// same `approvals --json` read as the questions.
    public var agentRequests: [AgentRequestJSON] = []
    public var paused: PausedJSON?
    public var questionsComplete = false
    public var questionsIssue: String?
    public var confirmedQuestionIDs: Set<String> = []
    public var pausedConfirmed = false
    /// False while the event stream is down: the UI shows `Live updates paused`.
    public var streamHealthy = false
    /// True once `app list --json` answered.
    public var listLoaded = false
    /// paddock's line when `app list --json` failed and no list is shown.
    public var listError: String?

    // MARK: UI state
    public var selection: SidebarItem?
    public var detailTab: DetailTab = .overview
    public var toast: Toast?
    /// Errors that show in place for one app: start refusals, crashes.
    public var appErrors: [String: LauncherError] = [:]
    /// The result line of `Check for newer macOS`.
    public var latestCheck: UIText?
    public var latestAvailable: String?
    /// True while this launcher runs the build child process.
    public var buildRunning = false
    /// A failed command, shown in place with paddock's line.
    public var lastError: LauncherError?
    /// The optional commands of this paddock (`app suspend`).
    public var capabilities = Capabilities()
    /// paddock's answer to Pause or Resume of a build, shown under the steps.
    public var buildNote: UIText?
    /// paddock's own line behind `buildNote`, for its "Details".
    public var buildNoteDetails: String?
    /// The app that waits for the base image. Add App keeps it there, the
    /// window shows its room with the build, and the add runs by itself
    /// when the base image is ready (`PendingAdd`).
    public var pendingAdd: PendingAdd?
    /// The room whose detail must show now: the app that was added, the
    /// agent that started. The Rooms layout opens it; the List layout
    /// shows a selected room anyway. The view that shows it clears it.
    public var openRoom: SidebarItem?
    /// The notices that the window shows, the newest first (`post`).
    public var notices: [Notice] = []
    /// True once the welcome window ended with Start or "Skip for now".
    /// The app keeps it in its settings.
    public var welcomeDone = false

    // MARK: Plumbing
    @ObservationIgnored public private(set) var service: PaddockService?
    @ObservationIgnored public let clock: LauncherClock
    @ObservationIgnored var gate = StatusGate()
    @ObservationIgnored var eventTask: Task<Void, Never>?
    @ObservationIgnored var buildTask: Task<Void, Never>?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    @ObservationIgnored var streamAttempt = 0
    /// Counts the starts. A start, or a read, whose serial is not the
    /// current one drops its result: Check Again fences the old paddock.
    @ObservationIgnored var startSerial = 0
    /// The check of the current start. A new start cancels it, which kills
    /// its paddock child.
    @ObservationIgnored var checkTask: Task<VersionGate.Verdict, Never>?
    @ObservationIgnored var questionSnapshotSerial: UInt64 = 0
    @ObservationIgnored var questionSnapshotPending = false
    @ObservationIgnored var questionTouches: Set<String> = []
    @ObservationIgnored var pauseTouched = false
    @ObservationIgnored var retiredPauseIDs: Set<String> = []
    /// Agent requests answered from the launcher. A listing read before the
    /// answer arrived still has them; they must not come back.
    @ObservationIgnored var answeredRequestIDs: Set<String> = []
    /// Per-app detail models, so grant events reach an open Grants tab.
    @ObservationIgnored public var details: [String: AppDetailModel] = [:]
    /// Sees every event of the stream first: the agent rooms read their
    /// runs again when the stream starts or lost events.
    @ObservationIgnored public var onEvent: ((PaddockEvent) -> Void)?
    /// Gets every new notice once: the app posts its notification.
    @ObservationIgnored public var onNotice: ((Notice) -> Void)?
    @ObservationIgnored var noticeBook = NoticeBook()
    @ObservationIgnored var postedNotices: Set<String> = []
    /// The time before a dead event stream is opened again.
    @ObservationIgnored public var reconnectDelay: Double = 5
    @ObservationIgnored public var toastSeconds: Double = 6

    /// A service given here counts as checked: tests pass one, the app
    /// passes nil and gets its service from `start`.
    public init(service: PaddockService?, clock: LauncherClock = SystemClock()) {
        self.service = service
        self.clock = clock
    }

    // MARK: Start

    /// Checks the binary, loads the snapshots and starts the event stream.
    /// `locate` returns the binary path or nil, `makeService` wraps it.
    ///
    /// The store keeps no service until `--version` and the launcher
    /// protocol both pass, so no read, stream or action reaches a paddock
    /// that the launcher cannot use. A new start (Check Again) first stops
    /// the stream and drops the old service. Of two overlapping starts, the
    /// last one wins.
    ///
    /// Limit: the check and the later calls run the binary at the same
    /// path. A binary replaced at that path in between is not seen until
    /// the next Check Again.
    public func start(locate: () -> String?, makeService: (String) -> PaddockService,
                      gate versionGate: VersionGate = .current) async {
        startSerial += 1
        let serial = startSerial
        checkTask?.cancel()
        checkTask = nil
        stopEvents()
        service = nil
        capabilities = Capabilities()
        binary = .checking
        guard let path = locate() else {
            binary = .missing
            return
        }
        let candidate = makeService(path)
        let check = Task { await LauncherStore.verdict(of: candidate, gate: versionGate) }
        checkTask = check
        let verdict = await check.value
        guard serial == startSerial else { return }
        checkTask = nil
        binary = .found(path: path, verdict: verdict)
        guard case .ok = verdict else { return }
        service = candidate
        let capabilities = await LibraryActions.probe(candidate)
        guard serial == startSerial else { return }
        self.capabilities = capabilities
        await refreshAll()
        guard serial == startSerial else { return }
        startEvents()
    }

    /// The verdict on a binary: `--version` in range, then the launcher
    /// protocol of the same binary. Both runs are bounded.
    public nonisolated static func verdict(of service: PaddockService,
                                           gate: VersionGate = .current) async -> VersionGate.Verdict {
        let output: String
        do {
            output = try await service.version()
        } catch CommandError.timedOut {
            return .incompatible(version: "", reason: .timedOut)
        } catch CommandError.tooLarge {
            return .incompatible(version: "", reason: .tooLarge)
        } catch {
            return gate.check(versionOutput: "")
        }
        let verdict = gate.check(versionOutput: output)
        guard case .ok(let version) = verdict else { return verdict }
        do {
            let answer = try await service.launcherProtocol()
            guard let failure = LauncherProtocol.check(answer) else {
                (service as? CLIPaddockService)?.notifies = LauncherProtocol.features(answer).contains(LauncherProtocol.notices)
                return verdict
            }
            return .incompatible(version: version, reason: failure)
        } catch {
            return .incompatible(version: version, reason: LauncherProtocol.failure(of: error))
        }
    }

    /// Loads every snapshot once: base image, apps, questions.
    public func refreshAll() async {
        guard let service else { return }
        let serial = startSerial
        if gate.allow("macvm status", now: clock.now()) {
            let status = try? await service.macvmStatus()
            guard serial == startSerial else { return }
            if let status { applyStatus(status) }
        }
        if gate.allow("app list", now: clock.now()) {
            do {
                let list = try await service.listApps()
                guard serial == startSerial else { return }
                applyList(list)
            } catch {
                guard serial == startSerial else { return }
                let line = LauncherStore.line(of: error)
                listError = line.isEmpty ? UIText("paddock did not list the apps. Click Try Again.").english : line
            }
        }
        await reloadApprovals()
    }

    /// Reads `approvals --json` again, at most once every 5 seconds: the
    /// app questions and the agent requests. The agent rooms call it while
    /// a run is live, as the event stream has no agent cards.
    public func reloadApprovals() async {
        guard let service, gate.allow("approvals", now: clock.now()) else { return }
        questionSnapshotSerial += 1
        let serial = questionSnapshotSerial
        questionSnapshotPending = true
        questionTouches.removeAll()
        pauseTouched = false
        retiredPauseIDs.removeAll()
        do {
            let approvals = try await service.approvals()
            guard serial == questionSnapshotSerial else { return }
            reconcileQuestions(approvals)
        } catch {
            guard serial == questionSnapshotSerial else { return }
            questionsComplete = false
            let line = LauncherStore.line(of: error)
            questionsIssue = line.isEmpty ? "Could not load questions." : line
            confirmedQuestionIDs = confirmedQuestionIDs.intersection(questionTouches)
            if !pauseTouched { pausedConfirmed = false }
        }
        questionSnapshotPending = false
    }

    func reconcileQuestions(_ snapshot: ApprovalsJSON) {
        reconcileAgentRequests(snapshot)
        let ids = Set(snapshot.questions.map(\.id))
        if snapshot.complete {
            questions.removeAll { !ids.contains($0.id) && !questionTouches.contains($0.id) }
        }
        confirmedQuestionIDs = confirmedQuestionIDs.intersection(questionTouches)
        for question in snapshot.questions where !questionTouches.contains(question.id) {
            if let index = questions.firstIndex(where: { $0.id == question.id }) {
                questions[index] = question
            } else {
                questions.append(question)
            }
            confirmedQuestionIDs.insert(question.id)
        }
        if !pauseTouched {
            var incoming = snapshot.paused
            if let id = incoming?.id, retiredPauseIDs.contains(id) { incoming = nil }
            if snapshot.complete || incoming != nil { paused = incoming }
            pausedConfirmed = incoming != nil
        }
        dropCardNotices()
        questionsComplete = snapshot.complete
        questionsIssue = snapshot.complete ? nil :
            (snapshot.diagnostics.isEmpty ? "The question list is incomplete." : snapshot.diagnostics.joined(separator: "\n"))
        if streamAttempt > 0 && !streamHealthy {
            confirmedQuestionIDs.removeAll()
            pausedConfirmed = false
            questionsComplete = false
            questionsIssue = "Live updates paused; questions are not confirmed."
        }
    }

    /// A complete listing replaces the agent requests; an incomplete one
    /// only adds and updates, so a card in doubt stays until it is known.
    /// A request answered here since the read began does not come back.
    func reconcileAgentRequests(_ snapshot: ApprovalsJSON) {
        let incoming = snapshot.requests.filter { !answeredRequestIDs.contains($0.id) }
        if snapshot.complete {
            agentRequests = incoming
            answeredRequestIDs = answeredRequestIDs.intersection(snapshot.requests.map(\.id))
            return
        }
        for request in incoming {
            if let index = agentRequests.firstIndex(where: { $0.id == request.id }) {
                agentRequests[index] = request
            } else {
                agentRequests.append(request)
            }
        }
    }

    func touchQuestion(_ id: String) {
        if questionSnapshotPending { questionTouches.insert(id) }
    }

    func retireQuestion(_ id: String) {
        touchQuestion(id)
        confirmedQuestionIDs.remove(id)
        questions.removeAll { $0.id == id }
        dismissNotice(Notice.questionPrefix + id)
    }

    /// The `Refresh` action (⌘R): restarts the stream and reloads. It does
    /// nothing without a checked paddock: Check Again runs the checks.
    public func refresh() async {
        guard service != nil else { return }
        gate.reset()
        startEvents()
        await refreshAll()
        for model in details.values { await model.load(force: true) }
    }

    public func applyStatus(_ status: MacvmStatusJSON) {
        goldenLoaded = true
        let next = GoldenState(json: status.golden)
        // Keep the stream-time samples of a running build.
        if case .building(let mine) = golden, case .building(let theirs) = next, buildRunning {
            var merged = mine
            merged.paused = theirs.paused
            golden = .building(merged)
        } else {
            golden = next
        }
        disk = status.disk ?? disk
        logDir = status.logDir ?? logDir
        goldenLogPath = status.golden.logPath ?? goldenLogPath
        // The app that waited for the base image is added now.
        startPendingAddIfReady()
    }

    public func applyList(_ list: [AppJSON]) {
        listLoaded = true
        listError = nil
        let before = apps.map(\.key)
        apps = list.map(AppItem.init(json:))
        // paddock 0.2.2 reports the free space only per profile.
        if let free = list.lazy.compactMap(\.hostDiskFree).first {
            var d = disk ?? DiskJSON(freeBytes: free)
            d.freeBytes = free
            disk = d
        }
        if case .app(let key)? = selection, !apps.contains(where: { $0.key == key }) {
            // The selected app left the list: the row after it, else the
            // one before, as a list does after a delete.
            let gone = Set(before).subtracting(apps.map(\.key))
            let next = LauncherStore.neighbor(of: key, in: before, removing: gone) ?? apps.first?.key
            selection = next.map { .app($0) }
        }
    }

    /// The row to select when the rows of `gone` leave `keys` and
    /// `selected` is one of them: the next row that stays, else the last
    /// one before it. Nil when no row stays.
    public nonisolated static func neighbor(of selected: String, in keys: [String], removing gone: Set<String>) -> String? {
        guard let index = keys.firstIndex(of: selected) else { return keys.first { !gone.contains($0) } }
        if let next = keys[(index + 1)...].first(where: { !gone.contains($0) }) { return next }
        return keys[..<index].last { !gone.contains($0) }
    }

    /// The row of a sidebar key: the profile name, or `NAME--N` for
    /// instance N.
    public func app(named key: String) -> AppItem? {
        apps.first { $0.key == key }
    }

    public var runningApps: [AppItem] { apps.filter { $0.state.isRunning } }
    public var activeApps: [AppItem] { apps.filter { $0.state.isActive } }

    public var selectedApp: AppItem? {
        if case .app(let name)? = selection { return app(named: name) }
        return nil
    }

    /// The welcome window shows when paddock is missing or unusable, and
    /// once on a Mac where paddock for Mac was not used yet: no welcome
    /// finished or skipped, no app, and no base image built or begun.
    ///
    /// A missing base image alone never opens it: the base image belongs
    /// to the Apps section (`addNeedsBaseImage`).
    public var needsOnboarding: Bool {
        switch binary {
        case .missing: return true
        case .found(_, let verdict):
            guard case .ok = verdict else { return true }
            guard !welcomeDone, goldenLoaded else { return false }
            return golden == .none && apps.isEmpty
        case .checking: return false
        }
    }

    /// True when Add App must first show the base image step: paddock
    /// said that no base image is there, and none is being built.
    public var addNeedsBaseImage: Bool {
        goldenLoaded && golden == .none
    }

    // MARK: Event stream

    /// Starts the event stream. Without a checked paddock it only stops
    /// the old one.
    public func startEvents() {
        guard service != nil else {
            stopEvents()
            return
        }
        eventTask?.cancel()
        markStreamUncertain()
        streamAttempt += 1
        let attempt = streamAttempt
        eventTask = Task { [weak self] in
            await self?.runEvents(attempt: attempt)
        }
    }

    public func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
        streamAttempt += 1
        markStreamUncertain()
    }

    func markStreamUncertain() {
        streamHealthy = false
        questionSnapshotSerial += 1
        questionSnapshotPending = false
        questionsComplete = false
        confirmedQuestionIDs.removeAll()
        pausedConfirmed = false
        questionsIssue = "Live updates paused; questions are not confirmed."
    }

    func runEvents(attempt: Int) async {
        while !Task.isCancelled, attempt == streamAttempt {
            guard let service else { return }
            // The first line follows subscription. Time alone does not prove
            // that the follower was registered before the snapshot.
            do {
                for try await event in service.events() {
                    if Task.isCancelled { break }
                    markHealthy(attempt: attempt)
                    apply(event)
                }
            } catch {}
            if Task.isCancelled || attempt != streamAttempt { return }
            markStreamUncertain()
            try? await clock.sleep(seconds: reconnectDelay)
        }
    }

    func markHealthy(attempt: Int) {
        guard attempt == streamAttempt, !streamHealthy else { return }
        streamHealthy = true
        // Include the gap before subscription even on the first connection.
        gate.reset("approvals")
        Task { await self.refreshAll() }
    }

    public func apply(_ event: PaddockEvent) {
        onEvent?(event)
        // A setup line tells its notice in `applySetup`: the lines of the
        // build child come there too.
        if case .setup = event {} else { note(event) }
        switch event {
        case .session(let e): applySession(e)
        case .question(let e): applyQuestion(e)
        case .grant(let e):
            details[e.app]?.apply(e)
        case .setup(let line): applySetup(line)
        case .golden(let op):
            if op == "removed" {
                golden = .none
            }
            Task { await self.reloadStatus() }
        case .disk(let free):
            if var d = disk {
                d.freeBytes = free
                disk = d
            } else {
                disk = DiskJSON(freeBytes: free)
            }
        case .stream(let state):
            // The follower missed events: read the state again.
            if state == "lost" {
                questionSnapshotSerial += 1
                questionSnapshotPending = false
                questionsComplete = false
                confirmedQuestionIDs.removeAll()
                pausedConfirmed = false
                questionsIssue = "Some live updates were missed; checking questions."
                gate.reset()
                Task { await self.refreshAll() }
            }
        case .notice, .deviceCall, .unknown:
            break
        }
    }

    func reloadStatus() async {
        guard let service, gate.allow("macvm status", now: clock.now()) else { return }
        let serial = startSerial
        let status = try? await service.macvmStatus()
        guard serial == startSerial else { return }
        if let status { applyStatus(status) }
    }

    func applySession(_ e: SessionEvent) {
        let key = InstanceRef(app: e.app, home: e.home).key
        if e.state == "removed" {
            let keys = apps.map(\.key)
            apps.removeAll { $0.key == key }
            details[key] = nil
            // Never an empty detail: the next row, or the empty state.
            if selection == .app(key) {
                selection = LauncherStore.neighbor(of: key, in: keys, removing: [key]).map { .app($0) }
            }
            return
        }
        guard let index = apps.firstIndex(where: { $0.key == key }) else {
            Task { await self.reloadList() }
            return
        }
        var json = apps[index].json
        if e.state == "agent" {
            json.agentConnected = e.connected
        } else {
            json.state = SessionWords.state(e)
            json.phase = e.phase
            if let since = e.since ?? (json.state == "running" || json.state == "saved" ? e.t : nil) { json.since = since }
            if let windows = e.windows { json.windows = windows }
            json.reason = e.reason ?? (json.state == "error" ? e.text : nil)
            json.blockCode = e.blockCode
            if let next = e.nextStart { json.nextStart = next }
            if json.state == "running" || json.state == "starting" { appErrors[key] = nil }
            if json.state == "error", e.crash != nil {
                appErrors[key] = .crashed(app: apps[index].title, crashRow: e.crash)
            }
        }
        apps[index] = AppItem(json: json)
        details[key]?.sessionChanged(apps[index])
    }

    func reloadList() async {
        guard let service, gate.allow("app list", now: clock.now()) else { return }
        let serial = startSerial
        let list = try? await service.listApps()
        guard serial == startSerial else { return }
        if let list { applyList(list) }
    }

    func applyQuestion(_ e: QuestionEvent) {
        switch e.state ?? e.op ?? "" {
        case "open":
            guard let id = e.id else { return }
            touchQuestion(id)
            confirmedQuestionIDs.insert(id)
            guard !questions.contains(where: { $0.id == id }) else { return }
            questions.append(QuestionJSON(id: id, app: e.app ?? "", host: e.host ?? "", port: e.port ?? 0,
                                          process: e.process, opened: e.opened ?? clock.now()))
        case "answered", "withdrawn":
            if let id = e.id { retireQuestion(id) }
        case "paused":
            if questionSnapshotPending { pauseTouched = true }
            paused = PausedJSON(app: e.app ?? "", count: e.open ?? e.count ?? 0, id: e.id)
            pausedConfirmed = true
        case "resumed":
            if questionSnapshotPending {
                if let id = e.id { retiredPauseIDs.insert(id) }
                else { pauseTouched = true }
            }
            if let current = paused, (e.id == nil || current.id == nil || e.id == current.id),
               (e.app == nil || e.app == current.app) {
                paused = nil
                pausedConfirmed = false
                if questionSnapshotPending { pauseTouched = true }
            }
        default:
            break
        }
    }

    func applySetup(_ line: SetupJSON) {
        note(.setup(line))
        if let failed = line.failed {
            golden = .failed(BuildFailure(step: BuildStep(json: line.step), code: failed.code, reason: failed.reason))
            return
        }
        if line.step == "done" {
            Task { await self.reloadStatus() }
            return
        }
        var progress: BuildProgress
        if case .building(let current) = golden { progress = current } else { progress = BuildProgress() }
        progress.apply(line)
        golden = .building(progress)
    }

    // MARK: Toasts

    public func show(_ text: UIText) {
        let toast = Toast(text)
        self.toast = toast
        toastTask?.cancel()
        let seconds = toastSeconds
        toastTask = Task { [weak self] in
            guard let self else { return }
            try? await self.clock.sleep(seconds: seconds)
            if !Task.isCancelled, self.toast?.id == toast.id { self.toast = nil }
        }
    }

    /// The model of an app's detail tabs, made on first use.
    public func detail(for name: String) -> AppDetailModel {
        if let model = details[name] { return model }
        let model = AppDetailModel(name: name, store: self)
        details[name] = model
        return model
    }
}
