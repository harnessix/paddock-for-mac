import Foundation

/// A message of paddock for Mac to you: an app that stopped, a base image
/// that is ready, an agent that waits. The app posts each notice itself,
/// with its own icon (`UNUserNotificationCenter`), and shows it in the
/// window. A click goes to `target`.
///
/// paddock's CLI posts its notifications through `osascript`, which shows
/// the Script Editor icon. The launcher never does that: every notice
/// comes from the event stream (`NoticeBook`), from the questions or from
/// the agent rooms.
public struct Notice: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case question, questionsPaused
        case agentWaiting, agentEnded, agentFailed
        case appFailed, appBlocked, appAdded, addFailed
        case buildReady, buildFailed
        /// A `notice` line of the event stream, in paddock's words.
        case message
    }

    /// One notification per id: a notice with a known id is not posted again.
    public var id: String
    public var kind: Kind
    public var title: UIText
    public var body: UIText
    /// Where a click goes. Nil opens the main window as it is.
    public var target: SidebarItem?
    /// The card of the Questions list to bring into view: the id of a
    /// question or of an agent request.
    public var card: String?

    public init(id: String, kind: Kind, title: UIText, body: UIText, target: SidebarItem?, card: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.target = target
        self.card = card
    }

    /// True when the notice names a problem: its symbol is the warning sign.
    public var isProblem: Bool {
        switch kind {
        case .appFailed, .appBlocked, .addFailed, .buildFailed, .agentFailed: return true
        default: return false
        }
    }

    /// True for a notice that also shows as a line in the window. The
    /// open questions and the agent rooms have their own places there
    /// (the Questions badge, the room), so their notices only notify.
    public var showsInWindow: Bool {
        switch kind {
        case .question, .agentWaiting, .agentEnded, .agentFailed: return false
        default: return true
        }
    }

    /// The SF Symbol of the notice in the window.
    public var symbol: String {
        switch kind {
        case .question, .agentWaiting: return "exclamationmark.bubble.fill"
        case .questionsPaused: return "pause.circle.fill"
        case .buildReady, .appAdded, .agentEnded: return "checkmark.circle.fill"
        case .message: return "bell.fill"
        case .appFailed, .appBlocked, .addFailed, .buildFailed, .agentFailed: return "exclamationmark.triangle.fill"
        }
    }

    /// The notice of an agent room.
    public init(agent notice: AgentNotice) {
        let kind: Kind
        switch notice.kind {
        case .waiting: kind = .agentWaiting
        case .ended: kind = .agentEnded
        case .failed: kind = .agentFailed
        }
        // A request opens the Questions list on its card; an end, the room.
        let request = notice.kind == .waiting && notice.id.hasPrefix(AgentNotice.requestPrefix)
            ? String(notice.id.dropFirst(AgentNotice.requestPrefix.count)) : nil
        self.init(id: notice.id, kind: kind, title: notice.title, body: notice.body,
                  target: request == nil ? .agent(notice.key) : .questions, card: request)
    }

    /// The notice of an app question that waited past the threshold.
    public init(question: QuestionJSON) {
        self.init(id: Notice.questionPrefix + question.id, kind: .question, title: QuestionNotifier.title(question),
                  body: QuestionsCopy.title(question), target: .questions, card: question.id)
    }

    public static let questionPrefix = "question-"
}

extension AgentNotice {
    /// The id of a request notice is this prefix and the request id.
    public static let requestPrefix = "agent-request-"
}

/// A notice as the `userInfo` of a notification, and back. Plain strings,
/// so the notification survives a restart of the launcher.
public enum NoticeRoute {
    public static let targetKey = "target"
    public static let cardKey = "card"

    public static func word(_ item: SidebarItem) -> String {
        switch item {
        case .app(let key): return "app:" + key
        case .agent(let key): return "agent:" + key
        case .questions: return "questions"
        case .baseImage: return "baseImage"
        case .agents: return "agents"
        }
    }

    public static func item(_ word: String) -> SidebarItem? {
        switch word {
        case "questions": return .questions
        case "baseImage": return .baseImage
        case "agents": return .agents
        default:
            if word.hasPrefix("app:") { return .app(String(word.dropFirst("app:".count))) }
            if word.hasPrefix("agent:") { return .agent(String(word.dropFirst("agent:".count))) }
            return nil
        }
    }

    public static func userInfo(_ notice: Notice) -> [String: String] {
        var info: [String: String] = [:]
        if let target = notice.target { info[targetKey] = word(target) }
        if let card = notice.card { info[cardKey] = card }
        return info
    }

    /// Where the click on a notification goes. A notification of an older
    /// launcher has `agent` and `kind`, or `question`.
    public static func destination(_ info: [String: String]) -> (target: SidebarItem?, card: String?) {
        if let word = info[targetKey] { return (item(word), info[cardKey]) }
        if let agent = info["agent"] {
            return info["kind"] == "waiting" ? (.questions, nil) : (.agent(agent), nil)
        }
        if let question = info["question"] { return (.questions, question) }
        return (nil, info[cardKey])
    }
}

/// A `notice` line of the event stream: what paddock would tell you with
/// a notification. The reader is lenient, as the kind is new: the title is
/// `title` or `summary`, the text is `text`, `body`, `message` or `detail`.
public struct NoticeEvent: Equatable, Sendable {
    public var id: String?
    public var title: String
    public var text: String
    /// The app profile the notice is about.
    public var app: String?
    public var home: String?
    /// The agent run the notice is about.
    public var run: String?
    /// `question`, `setup`, `golden` or another word of paddock (`what`
    /// of the notice line: `approval`, `new_host`, `frozen`, `info`).
    public var about: String?
    /// paddock asks for attention now: the notification has a sound.
    public var critical: Bool
    /// What answers the notice, for example the id of an agent request.
    public var action: String?

    public init(id: String? = nil, title: String, text: String, app: String? = nil, home: String? = nil,
                run: String? = nil, about: String? = nil, critical: Bool = false, action: String? = nil) {
        self.critical = critical
        self.action = action
        self.id = id
        self.title = title
        self.text = text
        self.app = app
        self.home = home
        self.run = run
        self.about = about
    }

    struct Raw: Decodable {
        var id: String?
        var title: String?
        var summary: String?
        var text: String?
        var body: String?
        var message: String?
        var detail: String?
        var app: String?
        var home: String?
        var sandbox: String?
        var run: String?
        var about: String?
        var topic: String?
        var what: String?
        var critical: Bool?
        var action: String?
    }

    /// Nil for a line with no words to show.
    public static func decode(_ data: Data) -> NoticeEvent? {
        guard let raw = try? PaddockJSON.decoder.decode(Raw.self, from: data) else { return nil }
        let texts = [raw.text, raw.body, raw.message, raw.detail].compactMap { $0 }.filter { !$0.isEmpty }
        let titles = [raw.title, raw.summary].compactMap { $0 }.filter { !$0.isEmpty }
        guard !texts.isEmpty || !titles.isEmpty else { return nil }
        // One line only: it is the text, under the name of the launcher.
        // paddock for Mac posts under its own name: a "paddock: " prefix of
        // the CLI is not repeated.
        var title = titles.first ?? "paddock"
        if title.hasPrefix("paddock: ") { title = String(title.dropFirst("paddock: ".count)) }
        let text = texts.first ?? ""
        return NoticeEvent(id: raw.id, title: title, text: text, app: raw.app, home: raw.home,
                           run: raw.run ?? raw.sandbox, about: raw.about ?? raw.topic ?? raw.what,
                           critical: raw.critical ?? false, action: raw.action)
    }

    /// Where a click on the notice goes.
    public var target: SidebarItem? {
        if let run, !run.isEmpty { return .agent(run) }
        if let app, !app.isEmpty { return .app(InstanceRef(app: app, home: home).key) }
        switch about {
        case "question"?, "questions"?, "approval"?, "approvals"?: return .questions
        case "setup"?, "golden"?, "macvm"?: return .baseImage
        default: return nil
        }
    }
}

/// Turns the events of `paddock events --follow --json` into notices: one
/// for each change that paddock's CLI would post a notification for. The
/// book remembers what it told, so a state that repeats is told once.
///
/// - an app session that ends in `error`, or that is `blocked`
/// - a base image build that failed, and one that is done
/// - questions that paddock paused
/// - a `notice` line, shown in paddock's words
///
/// The open questions and the agent rooms notify from their own lists
/// (`QuestionNotifier`, `AgentNotifier`), after the time of the setting.
public struct NoticeBook: Equatable, Sendable {
    private var failedApps: Set<String> = []
    private var blockedApps: Set<String> = []
    private var pausedIDs: Set<String> = []
    private var buildFailure: String?
    private var buildReady = false
    private var serial = 0

    public init() {}

    /// The key of the app an event is about, for its title.
    public static func appKey(of event: PaddockEvent) -> String? {
        switch event {
        case .session(let e): return InstanceRef(app: e.app, home: e.home).key
        case .question(let e): return e.app
        case .notice(let e): return e.app.map { InstanceRef(app: $0, home: e.home).key }
        default: return nil
        }
    }

    /// The notices of one event. `appTitle` is the name on screen of the
    /// app of `appKey(of:)`.
    public mutating func notices(for event: PaddockEvent, appTitle: String? = nil) -> [Notice] {
        switch event {
        case .session(let e): return session(e, title: appTitle)
        case .setup(let line): return setup(line)
        case .golden(let op):
            if op == "ready" { return ready() }
            if op == "removed" { buildReady = false }
            return []
        case .question(let e): return question(e, title: appTitle)
        case .notice(let e):
            serial += 1
            return [Notice(id: e.id.map { "notice-" + $0 } ?? "notice-\(serial)-\(e.title)-\(e.text)", kind: .message,
                           title: UIText.cli(e.title, else: UIText("paddock has a message")), body: UIText.cli(e.text, else: UIText("Open paddock for Mac to see what happened.")),
                           target: e.target, card: e.action)]
        case .grant, .disk, .stream, .deviceCall, .unknown:
            return []
        }
    }

    private mutating func session(_ e: SessionEvent, title: String?) -> [Notice] {
        let key = InstanceRef(app: e.app, home: e.home).key
        let name = title ?? key
        switch SessionWords.state(e) {
        case "error":
            blockedApps.remove(key)
            guard failedApps.insert(key).inserted else { return [] }
            serial += 1
            let reason = e.reason ?? e.text ?? ""
            let body = reason.isEmpty ? UIText("Open paddock for Mac to see what happened.") : UIText.cli(reason, else: UIText("Open paddock for Mac to see what happened."))
            return [Notice(id: "app-failed-\(key)-\(serial)", kind: .appFailed,
                           title: UIText("%@ stopped unexpectedly", name), body: body, target: .app(key))]
        case "blocked":
            failedApps.remove(key)
            guard blockedApps.insert(key).inserted else { return [] }
            serial += 1
            let reason = e.reason ?? e.text ?? ""
            let body = reason.isEmpty ? UIText("Open paddock for Mac to see what happened.") : UIText.cli(reason, else: UIText("Open paddock for Mac to see what happened."))
            return [Notice(id: "app-blocked-\(key)-\(serial)", kind: .appBlocked,
                           title: UIText("%@ cannot start", name), body: body, target: .app(key))]
        case "agent", "added":
            return []
        default:
            // Any other state ends the error: the next one is news again.
            failedApps.remove(key)
            blockedApps.remove(key)
            return []
        }
    }

    private mutating func setup(_ line: SetupJSON) -> [Notice] {
        if let failed = line.failed {
            buildReady = false
            guard buildFailure != failed.reason else { return [] }
            buildFailure = failed.reason
            serial += 1
            let failure = BuildFailure(step: BuildStep(json: line.step), code: failed.code, reason: failed.reason)
            return [Notice(id: "build-failed-\(serial)", kind: .buildFailed, title: UIText("Base image not built"),
                           body: failure.problem.message, target: .baseImage)]
        }
        buildFailure = nil
        if line.step == "done" { return ready() }
        buildReady = false
        return []
    }

    private mutating func ready() -> [Notice] {
        guard !buildReady else { return [] }
        buildReady = true
        buildFailure = nil
        serial += 1
        return [Notice(id: "build-ready-\(serial)", kind: .buildReady, title: UIText("Base image ready"),
                       body: UIText("Your Mac apps can get their rooms now."), target: .baseImage)]
    }

    private mutating func question(_ e: QuestionEvent, title: String?) -> [Notice] {
        let id = e.id ?? e.app ?? ""
        switch e.state ?? e.op ?? "" {
        case "paused":
            guard pausedIDs.insert(id).inserted else { return [] }
            let paused = PausedJSON(app: title ?? e.app ?? "", count: e.open ?? e.count ?? 0, id: e.id)
            return [Notice(id: "paused-" + id, kind: .questionsPaused, title: UIText("Questions paused"),
                           body: QuestionsCopy.pausedBanner(paused), target: .questions)]
        case "resumed":
            pausedIDs.remove(id)
            return []
        default:
            return []
        }
    }
}

extension LauncherStore {
    /// The notices the store keeps of each sort (those of the window
    /// line, and the others): the newest first.
    public static let noticesKept = 5

    /// Shows a notice in the window and hands it to the app, which posts
    /// the notification. A notice whose id was posted before does nothing.
    public func post(_ notice: Notice) {
        guard postedNotices.insert(notice.id).inserted else { return }
        notices.insert(notice, at: 0)
        // The newest few of each sort stay: the notices of the questions
        // and the agents never push a line of the window out.
        var inWindow = 0
        var others = 0
        notices = notices.filter { kept in
            if kept.showsInWindow {
                inWindow += 1
                return inWindow <= LauncherStore.noticesKept
            }
            others += 1
            return others <= LauncherStore.noticesKept
        }
        onNotice?(notice)
    }

    /// The notice goes from the window: you closed it, or you went there.
    public func dismissNotice(_ id: String) {
        notices.removeAll { $0.id == id }
    }

    /// The notices of an event of the stream.
    func note(_ event: PaddockEvent) {
        let name = NoticeBook.appKey(of: event).map { title(of: $0) }
        var book = noticeBook
        let found = book.notices(for: event, appTitle: name)
        noticeBook = book
        for notice in found { post(notice) }
    }

    /// The notices of cards that are gone leave the window: an answered
    /// question, an agent request that got its answer.
    func dropCardNotices() {
        let open = Set(questions.map(\.id)).union(agentRequests.map(\.id))
        notices.removeAll { notice in
            guard notice.kind == .question || notice.kind == .agentWaiting, let card = notice.card else { return false }
            return !open.contains(card)
        }
    }
}
