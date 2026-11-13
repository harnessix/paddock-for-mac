import Foundation

/// What the page of a failed run says above its terminal: what failed in
/// plain words, the next step, and the buttons for it. paddock's own line
/// goes under "Details", never as the message: the launcher reads the line
/// only to choose the words.
public struct AgentFailure: Equatable, Sendable {
    /// What failed.
    public enum Kind: String, CaseIterable, Equatable, Sendable {
        /// The agent program is not on this Mac.
        case agentMissing
        /// The agent has no login or no API key in the sandbox.
        case notLoggedIn
        /// A copy (`--worktree`) needs a git repository with a commit.
        case notGitRepository
        /// Another run uses the same project.
        case alreadyRuns
        case noSpace
        case noNetwork
        /// paddock could not start the sandbox itself.
        case sandbox
        /// This paddock does not know an option of the start.
        case oldPaddock
        /// macOS ended the agent (SIGKILL): low memory, most of the time.
        case killed
        /// A signal stopped the agent, not your Stop.
        case interrupted
        /// The agent stopped itself with a `blocked:` status.
        case blocked
        /// A failure that the launcher does not know.
        case unknown
    }

    /// A button of the card.
    public enum Step: String, Equatable, Sendable {
        /// Start the same agent in the same project again.
        case startAgain
        /// Show the output of the run: its terminal, or a view of it.
        case openLog
        /// Copy the update command of paddock.
        case updatePaddock
        /// Go to the other runs, to stop the one in the way.
        case showAgents

        public var title: UIText {
            switch self {
            case .startAgain: return UIText("Start Again")
            case .openLog: return UIText("Open the Log")
            case .updatePaddock: return UIText("Update paddock")
            case .showAgents: return UIText("Show All Agents")
            }
        }
    }

    public var kind: Kind
    /// paddock's line that the words come from, word for word. Nil when
    /// paddock gave none.
    public var line: String?
    /// The exit code of the agent, when paddock or the pane says it.
    public var exitCode: Int?

    public init(kind: Kind, line: String? = nil, exitCode: Int? = nil) {
        self.kind = kind
        self.line = line
        self.exitCode = exitCode
    }

    /// What failed, in one plain sentence.
    public var message: UIText {
        switch kind {
        case .agentMissing: return UIText("The agent is not installed on this Mac.")
        case .notLoggedIn: return UIText("The agent is not logged in.")
        case .notGitRepository:
            return UIText("The project is not a git repository with a commit, so the agent cannot work on a copy.")
        case .alreadyRuns: return UIText("Another run already uses this project.")
        case .noSpace: return UIText("There is not enough free disk space.")
        case .noNetwork: return UIText("The agent could not reach the network.")
        case .sandbox: return UIText("paddock could not start the sandbox.")
        case .oldPaddock: return UIText("This paddock does not know an option of this start.")
        case .killed: return UIText("macOS ended the agent. This happens when the Mac is low on memory.")
        case .interrupted: return UIText("A signal stopped the agent.")
        case .blocked: return UIText("The agent stopped because it is blocked.")
        case .unknown: return UIText("The agent stopped with an error.")
        }
    }

    /// The next step, in one sentence.
    public var next: UIText {
        switch kind {
        case .agentMissing: return UIText("Install the agent in Terminal, then start again.")
        case .notLoggedIn: return UIText("Start again, then log in inside the sandbox.")
        case .notGitRepository: return UIText("Make a first commit in the project, or start again without a copy.")
        case .alreadyRuns: return UIText("Stop the other run, then start again.")
        case .noSpace: return UIText("Free some disk space, then start again.")
        case .noNetwork: return UIText("Check the network, then start again.")
        case .sandbox: return UIText("Open the log to see why. If the log names a missing part, update paddock.")
        case .oldPaddock: return UIText("Update paddock, then start again.")
        case .killed: return UIText("Quit some apps, then start again.")
        case .interrupted: return UIText("Start again when you are ready.")
        case .blocked: return UIText("Open the log to read what the agent needs, then start again.")
        case .unknown: return UIText("Open the log to see what happened, then start again.")
        }
    }

    /// The buttons, the first one is the default.
    public var steps: [Step] {
        switch kind {
        case .agentMissing, .notLoggedIn, .notGitRepository, .noSpace, .noNetwork, .killed, .interrupted:
            return [.startAgain, .openLog]
        case .alreadyRuns: return [.showAgents, .startAgain]
        case .sandbox: return [.openLog, .updatePaddock]
        case .oldPaddock: return [.updatePaddock, .openLog]
        case .blocked, .unknown: return [.openLog, .startAgain]
        }
    }

    /// The update command that "Update paddock" copies.
    public static let updateCommand = ShellCommands.brewUpgrade

    // MARK: Reading the failure

    /// The failure of a room, or nil when the run did not fail. `screen`
    /// is the text of its terminal pane, when the launcher has one: a run
    /// that failed before paddock listed it says why only there.
    public static func of(_ room: AgentRoom, screen: String? = nil) -> AgentFailure? {
        guard case .failed(let reason) = room.state else { return nil }
        // paddock's words, the most precise first: the end status of the
        // run, its error notes, the state line, the last error on screen.
        let errorNote = room.notes?.last { $0.level == .error }?.text
        let candidates = [room.endReason, errorNote, reason, screen.flatMap(line(fromScreen:))]
        let lines = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let code = room.exitCode
        for text in lines {
            if let kind = kind(of: text) { return AgentFailure(kind: kind, line: text, exitCode: code) }
        }
        if let kind = kind(exitCode: code) { return AgentFailure(kind: kind, line: lines.first, exitCode: code) }
        let blocked = lines.contains { $0.lowercased().hasPrefix("blocked:") }
        return AgentFailure(kind: blocked ? .blocked : .unknown, line: lines.first, exitCode: code)
    }

    /// The kind of a known line of paddock or of the agent. Nil for a line
    /// that the launcher does not know.
    public static func kind(of line: String) -> Kind? {
        var text = line.lowercased()
        if text.hasPrefix("blocked:") { text = String(text.dropFirst("blocked:".count)) }
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("unrecognized", "unexpected argument", "unknown command", "unknown option", "usage:",
               "found argument", "invalid value for") {
            return .oldPaddock
        }
        if has("not a git repository", "needs at least one commit", "no commit", "worktree needs") { return .notGitRepository }
        if has("already runs", "already running", "already uses") { return .alreadyRuns }
        if has("no space", "disk is full", "not enough space", "free space", "enospc") { return .noSpace }
        if has("cannot start the sandbox", "could not start the sandbox", "paddock-vm", "virtualization", "bwrap",
               "sandbox backend", "cannot start the vm", "the vm did not start") {
            return .sandbox
        }
        if has("is not installed", "not on path", "command not found", "no such harness", "unknown harness") {
            return .agentMissing
        }
        if has("api key", "not logged in", "log in", "login", "unauthorized", "authentication",
               "credentials", "oauth") {
            return .notLoggedIn
        }
        if has("could not resolve", "connection refused", "network is unreachable", "connection timed out",
               "no network", "offline", "connection reset") {
            return .noNetwork
        }
        return nil
    }

    /// The kind of an exit code with no known line: a signal.
    static func kind(exitCode: Int?) -> Kind? {
        switch exitCode {
        case 137?: return .killed
        case 129?, 130?, 131?, 143?: return .interrupted
        default: return nil
        }
    }

    /// The line of a terminal screen that says why the run failed: the
    /// last line with `error`, else the last line of paddock, else nil.
    /// paddock prints its errors even with `--quiet`.
    public static func line(fromScreen screen: String) -> String? {
        let lines = screen.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let error = lines.last(where: { $0.lowercased().contains("error") }) { return error }
        return lines.last { $0.lowercased().hasPrefix("paddock:") }
    }
}
