import Foundation

// The rules of the screens that have no view in them: what the one
// prominent action of an app is, what the storage section says before
// there is data, how old a request is, and how a build shows as one
// progress. The views draw; these decide. The tests are in ScreenTests.

// MARK: - The app hero

/// The one prominent action in the hero of an app.
///
/// An app cannot start without the base image. Then the action says so
/// and leads to the base image page, in place of a Start that fails.
public enum HeroAction: Equatable, Sendable {
    case start, resume, open
    /// No base image, or a build that failed: the action starts the setup.
    case buildBaseImage
    /// The base image builds: the action shows the build.
    case showBuild

    public static func of(_ state: AppState, golden: GoldenState, goldenLoaded: Bool) -> HeroAction? {
        if state.isRunning { return .open }
        if state.canResume { return .resume }
        var needsImage = state.canStart
        if case .blocked(_, "no_golden"?) = state { needsImage = true }
        guard needsImage else { return nil }
        // paddock did not say yet whether a base image is there: Start.
        guard goldenLoaded else { return state.canStart ? .start : nil }
        switch golden {
        case .ready, .needsUpdate: return state.canStart ? .start : nil
        case .building: return .showBuild
        case .none, .failed: return .buildBaseImage
        }
    }

    public var title: UIText {
        switch self {
        case .start: return UIText("Start")
        case .resume: return UIText("Resume")
        case .open: return UIText("Open")
        case .buildBaseImage: return UIText("Build the Base Image…")
        case .showBuild: return UIText("Show the Build")
        }
    }

    /// The sentence under the state when the action is about the base
    /// image: why Start is not there.
    public var note: UIText? {
        switch self {
        case .buildBaseImage: return UIText("This app can start when the base image is built. You build it once, for all apps.")
        case .showBuild: return UIText("The base image builds now. This app can start when it is ready.")
        default: return nil
        }
    }

    /// The accessibility identifier of the button.
    public var identifier: String {
        switch self {
        case .start: return "start-button"
        case .resume: return "resume-button"
        case .open: return "open-button"
        case .buildBaseImage: return "hero-build-base-image"
        case .showBuild: return "hero-show-build"
        }
    }
}

// MARK: - Storage of an app

/// What the Storage group of an app shows. Before the first start paddock
/// reports zero bytes: the group then says what will happen, and shows
/// no empty bar and no zero.
public enum StorageSummary: Equatable, Sendable {
    case nothingYet
    /// The three parts, for the bar and its legend.
    case parts(AppSizesJSON)
    /// One number: paddock gave no parts.
    case total(Int64)

    public static func of(_ app: AppJSON) -> StorageSummary {
        if let sizes = app.sizes, sizes.total > 0 { return .parts(sizes) }
        if let bytes = app.bytes, bytes > 0 { return .total(bytes) }
        return .nothingYet
    }

    public static let nothingYetLine = UIText("Nothing stored yet. The first start prepares the app.")

    /// True when Clear saved state has something to clear, and the app
    /// does not hold the state now.
    public static func canClearSavedState(_ app: AppJSON, state: AppState) -> Bool {
        (app.sizes?.savedState ?? 0) > 0 && !state.holdsSession
    }
}

// MARK: - The age of a request

/// How old a question or a request is, and when it counts as expired.
public enum RequestAge {
    /// A request that nobody answered for a day is old: the app or the
    /// agent that asked went on, or ended.
    public static let expiresAfter: TimeInterval = 24 * 60 * 60

    /// `Asked 3 d ago`.
    public static func asked(_ date: Date?, now: Date) -> UIText? {
        guard let date else { return nil }
        return UIText("Asked %@", Format.age(since: date, now: now))
    }

    public static func isExpired(asked: Date?, expires: Date? = nil, now: Date) -> Bool {
        if let expires, expires <= now { return true }
        guard let asked else { return false }
        return now.timeIntervalSince(asked) >= expiresAfter
    }

    public static func isExpired(_ question: QuestionJSON, now: Date) -> Bool {
        isExpired(asked: question.opened, now: now)
    }

    public static func isExpired(_ request: AgentRequestJSON, now: Date) -> Bool {
        isExpired(asked: request.created, expires: request.expires, now: now)
    }

    /// `2 requests are older than a day or timed out.`
    public static func expiredLine(_ count: Int) -> UIText {
        count == 1 ? UIText("1 request is older than a day or timed out.")
            : UIText("%lld requests are older than a day or timed out.", count)
    }

    public static let clearNote = UIText("Clear Expired answers No to each of them.")
}

// MARK: - The build as one progress

extension BuildProgress {
    /// The share of the whole build of each step, by its usual time: the
    /// download is the long part.
    static let bands: [BuildStep: ClosedRange<Double>] = [
        .download: 0.0...0.6, .install: 0.6...0.85, .guided: 0.85...0.95, .seal: 0.95...1.0,
    ]

    /// The build as one number, 0 to 1. Inside the download it follows
    /// the bytes; the later steps stand at their start.
    public var overallFraction: Double {
        if done { return 1 }
        guard let band = BuildProgress.bands[step] else { return 0 }
        guard step == .download, total > 0 else { return band.lowerBound }
        let part = min(1, max(0, Double(bytes) / Double(total)))
        return band.lowerBound + (band.upperBound - band.lowerBound) * part
    }

    /// What the build does now, as the title of the page.
    public var headline: UIText {
        if done { return UIText("Base image ready") }
        switch step {
        case .download: return paused ? UIText("Download paused") : UIText("Downloading macOS")
        case .install: return UIText("Installing macOS")
        case .guided: return UIText("Setting up macOS")
        case .seal: return UIText("Sealing the base image")
        }
    }

    /// The time estimate under the progress. Before the rate is stable
    /// it is the usual time of the whole build.
    public var estimate: UIText {
        if paused { return UIText("Paused. Resume continues where it stopped.") }
        switch step {
        case .download:
            if showsEstimate { return Format.timeLeft(seconds: Double(total - bytes) / rate) }
            return UIText("Usually 10 to 30 minutes in total")
        case .install: return UIText("About 10 minutes left")
        case .guided: return UIText("A few minutes left")
        case .seal: return UIText("Less than a minute left")
        }
    }
}

// MARK: - The toolbar

/// Which toolbar items a page has. An item shows only where it acts.
public enum ToolbarRule {
    /// The List / Rooms switch: on the Apps pages when there are apps,
    /// and on the Agents pages when there are runs. Questions and Base
    /// image have one layout.
    public static func showsLayoutSwitch(_ selection: SidebarItem?, apps: Int, agents: Int) -> Bool {
        switch selection {
        case .questions?, .baseImage?: return false
        case .agents?, .agent?: return agents > 0
        case .app?, nil: return apps > 0
        }
    }
}

/// The title of the window: the page, not the name of the app again.
public enum WindowTitle {
    public static func of(_ selection: SidebarItem?, appTitle: String?, agentTitle: UIText?) -> UIText {
        switch selection {
        case .app?: return appTitle.map(UIText.verbatim) ?? UIText("Apps")
        case .agent?: return agentTitle ?? UIText("Agents")
        case .agents?: return UIText("Agents")
        case .questions?: return UIText("Questions")
        case .baseImage?: return UIText("Base image")
        case nil: return UIText("paddock for Mac")
        }
    }
}

// MARK: - The home page

/// What the window says when nothing is selected: where things stand,
/// and the one thing to do next.
public enum NextStep: Equatable, Sendable {
    /// Requests wait for an answer.
    case answer(Int)
    /// Nothing runs yet: the first agent.
    case firstAgent
    /// There are apps or runs: start another agent.
    case newAgent

    public static func of(waiting: Int, agents: Int, apps: Int) -> NextStep {
        if waiting > 0 { return .answer(waiting) }
        if agents == 0, apps == 0 { return .firstAgent }
        return .newAgent
    }

    public var title: UIText {
        switch self {
        case .answer(1): return UIText("1 request waits for your answer")
        case .answer(let count): return UIText("%lld requests wait for your answer", count)
        case .firstAgent: return UIText("Start your first agent")
        case .newAgent: return UIText("What do you want to work on?")
        }
    }

    public var action: UIText {
        switch self {
        case .answer: return UIText("Show the Requests")
        case .firstAgent, .newAgent: return UIText("New Agent…")
        }
    }

    /// `2 agents · 3 apps`, the line under the name. Nil when there is
    /// nothing to count.
    public static func summary(agents: Int, apps: Int) -> UIText? {
        var parts: [UIText] = []
        if agents == 1 { parts.append(UIText("1 agent")) }
        if agents > 1 { parts.append(UIText("%lld agents", agents)) }
        if apps == 1 { parts.append(UIText("1 app")) }
        if apps > 1 { parts.append(UIText("%lld apps", apps)) }
        switch parts.count {
        case 0: return nil
        case 1: return parts[0]
        default: return UIText("%@ · %@", parts[0], parts[1])
        }
    }
}

// MARK: - Agents with no run

/// Why the Agents page is empty. paddock looks for the agents in the
/// folders of your shell: when it found none, the page says so, and New
/// Agent alone would lead to an empty list.
public enum AgentsEmpty: Equatable, Sendable {
    /// No run yet. The usual empty state.
    case noRuns
    /// paddock listed its agents and none is installed.
    case noneInstalled

    public static func of(loaded: Bool, installed: Int) -> AgentsEmpty {
        loaded && installed == 0 ? .noneInstalled : .noRuns
    }

    public var title: UIText {
        switch self {
        case .noRuns: return UIText("No agents yet")
        case .noneInstalled: return UIText("No agent found on this Mac")
        }
    }

    public var text: UIText {
        switch self {
        case .noRuns:
            return UIText("Start Claude Code, Codex or another coding agent on a project folder. It works in a sandbox, and you answer what it asks here.")
        case .noneInstalled:
            return UIText("paddock looked in the folders of your shell and found no coding agent. Install one, such as Claude Code or Codex, then look again.")
        }
    }
}

// MARK: - Features of a newer paddock

/// A feature whose command this paddock does not have yet.
///
/// The window never shows a page of "cannot". A list that this paddock
/// cannot give is one quiet line: what shows there, and the paddock that
/// brings it. An action says the same in one line, with no command to
/// copy and no error.
public enum ComingFeature: String, CaseIterable, Equatable, Sendable {
    /// The lists of the Grants tab.
    case rules, connections, clipboard
    /// The actions on them.
    case changeRules, sessionClipboard, keepFolder

    /// The first paddock that has the commands (`app rules --json`,
    /// `app connections --json`, `app clipboard --session --json`,
    /// `app share keep`).
    public static let version = "0.2.4"

    /// What the feature does, in the present: the place is there, the
    /// content comes with the newer paddock.
    public var promise: UIText {
        switch self {
        case .rules: return UIText("The servers that this app may reach show here.")
        case .connections: return UIText("The connections of this app show here as they happen.")
        case .clipboard: return UIText("The clipboard between this app and your Mac is set here.")
        case .changeRules: return UIText("You change the rules of this app here.")
        case .sessionClipboard: return UIText("You set the clipboard of one session here.")
        case .keepFolder: return UIText("You keep a folder of this session for the next ones here.")
        }
    }

    /// `Needs paddock 0.2.4`.
    public static let needs = UIText("Needs paddock %@", version)

    /// Both in one line, after an action: `You keep a folder… Needs paddock 0.2.4.`
    public var line: UIText {
        UIText("%@ %@.", promise, ComingFeature.needs)
    }
}

/// The words under the network mode of an app, when paddock's own
/// sentence has no text in the language of the interface.
public enum NetworkCopy {
    public static func modeNote(_ mode: NetworkMode) -> UIText {
        switch mode {
        case .ask: return UIText("paddock asks you the first time the app reaches a new server.")
        case .allowlist: return UIText("The app reaches only the servers of its rules.")
        case .none: return UIText("The app reaches no server.")
        }
    }
}

// MARK: - Dates

extension Format {
    /// `3 Nov` as a text: each language has its own order and month name.
    public static func dayMonthText(_ date: Date, timeZone: TimeZone = .current) -> UIText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month], from: date)
        let day = "\(parts.day ?? 1)"
        switch parts.month ?? 1 {
        case 1: return UIText("%@ Jan", day)
        case 2: return UIText("%@ Feb", day)
        case 3: return UIText("%@ Mar", day)
        case 4: return UIText("%@ Apr", day)
        case 5: return UIText("%@ May", day)
        case 6: return UIText("%@ Jun", day)
        case 7: return UIText("%@ Jul", day)
        case 8: return UIText("%@ Aug", day)
        case 9: return UIText("%@ Sep", day)
        case 10: return UIText("%@ Oct", day)
        case 11: return UIText("%@ Nov", day)
        default: return UIText("%@ Dec", day)
        }
    }
}

// MARK: - Words of paddock in the agent rooms

extension AgentNetwork {
    /// The network level of a run as paddock names it (`none`, `api`,
    /// `egress`), in the words of the New Agent sheet.
    public static func text(_ raw: String) -> UIText {
        if let level = AgentNetwork(rawValue: raw) { return level.title }
        return UIText.cli(raw, else: UIText("Not known"))
    }
}
