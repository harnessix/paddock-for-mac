import Foundation

/// The network of an agent run: `paddock run --network`. `host` stays out
/// of the sheet: it gives the agent the whole network of the Mac.
public enum AgentNetwork: String, CaseIterable, Equatable, Sendable, Identifiable {
    case none, api, egress

    public var id: String { rawValue }

    public var title: UIText {
        switch self {
        case .none: return UIText("No network")
        case .api: return UIText("Only its AI service")
        case .egress: return UIText("The internet")
        }
    }

    /// The plain words under the choice.
    public var detail: UIText {
        switch self {
        case .none: return UIText("The agent cannot reach any server, not even its AI service.")
        case .api: return UIText("The agent reaches only the servers of its AI service. Recommended.")
        case .egress: return UIText("The agent reaches any server on the internet, but not your Mac or your local network.")
        }
    }
}

/// How the agent works: asking you before each step (manual mode), or on
/// its own in the sandbox (paddock's auto-approval flags). Manual is the
/// first case: it is the default, and the first choice of every list.
public enum AgentMode: String, CaseIterable, Equatable, Sendable, Identifiable {
    case manual, auto

    public var id: String { rawValue }

    /// The mode of a start before the user chose one: a new user, and an
    /// agent with no saved choice. This is the one place that names it.
    /// Full auto is an opt-in.
    public static let initial: AgentMode = .manual

    /// The order where the approval comes first: the New Agent sheet and
    /// step 3 of the welcome window. Full auto is the second choice.
    public static let manualFirst: [AgentMode] = [.manual, .auto]

    /// The title. No mode is marked as recommended, so this is `title`.
    public var plainTitle: UIText { title }

    public var title: UIText {
        switch self {
        case .auto: return UIText("Full auto in the sandbox")
        case .manual: return UIText("Ask me before each step")
        }
    }

    public var detail: UIText {
        switch self {
        case .auto: return UIText("The agent works without asking you. The sandbox keeps your Mac and your files outside the project safe.")
        case .manual: return UIText("The agent asks you before it runs a command or changes a file. You answer in its terminal.")
        }
    }

    /// The flag of manual mode: `--manual` when this paddock has it, else
    /// `--no-yolo`, which starts the agent without its auto-approval flags.
    public static func manualFlag(runHelp text: String?) -> String {
        guard let text else { return "--no-yolo" }
        let hasManual = text.split(separator: "\n").contains { line in
            line.split(separator: " ", omittingEmptySubsequences: true).contains { $0 == "--manual" }
        }
        return hasManual ? "--manual" : "--no-yolo"
    }
}

/// The mode of the last start of each agent, in the launcher's settings.
/// `read` gives the saved text of one key, or nil.
///
/// An older launcher saved one mode for all agents under `legacyKey`. A
/// user of it keeps that mode for an agent with no choice of its own. A
/// new user has no key, and starts each agent in `AgentMode.initial`.
public enum AgentModeMemory {
    /// The one key of the older launcher: `auto` or `manual`. This
    /// launcher reads it and does not write it.
    public static let legacyKey = "agentMode"

    /// The key of one agent: `agentMode.claude`.
    public static func key(_ harness: String) -> String { legacyKey + "." + harness }

    /// True for the key of an agent, for the reset of the settings.
    public static func isAgentKey(_ key: String) -> Bool {
        key.count > legacyKey.count + 1 && key.hasPrefix(legacyKey + ".")
    }

    /// The saved mode of each agent that has one.
    public static func modes(_ harnesses: [String], read: (String) -> String?) -> [String: AgentMode] {
        var modes: [String: AgentMode] = [:]
        for harness in harnesses {
            if let mode = read(key(harness)).flatMap(AgentMode.init(rawValue:)) { modes[harness] = mode }
        }
        return modes
    }

    /// The mode of an agent with no saved choice.
    public static func fallback(read: (String) -> String?) -> AgentMode {
        read(legacyKey).flatMap(AgentMode.init(rawValue:)) ?? AgentMode.initial
    }
}

/// What the New Agent sheet starts: one harness in one folder.
public struct AgentLaunch: Equatable, Sendable {
    public var harness: String
    public var folder: String
    public var network: AgentNetwork
    /// `--worktree`: the agent works in a new git worktree on its own branch.
    public var worktree: Bool
    public var mode: AgentMode

    public init(harness: String, folder: String, network: AgentNetwork = .api, worktree: Bool = false,
                mode: AgentMode = AgentMode.initial) {
        self.harness = harness
        self.folder = folder
        self.network = network
        self.worktree = worktree
        self.mode = mode
    }

    /// `run claude --network api [--worktree] [--no-yolo]`. The folder is
    /// the working directory of the process, not an argument: paddock
    /// widens it to its git root as in a terminal.
    public var args: [String] { args(manualFlag: "--no-yolo") }

    /// The arguments with the manual flag of this paddock.
    public func args(manualFlag: String) -> [String] {
        AgentArgs.run(harness, network: network, worktree: worktree, manualFlag: mode == .manual ? manualFlag : nil)
    }
}

/// The paddock arguments of the agent rooms. One place, as `PaddockArgs`.
public enum AgentArgs {
    public static let list = ["list", "--json"]
    public static let recent = ["recent", "--json"]
    public static let ps = ["ps", "--json"]
    public static let board = ["board", "--json"]
    /// The mailboxes of the runs, for their unread questions.
    public static let mail = ["mail", "ls", "--json"]

    public static let runHelp = ["run", "--help"]

    public static func run(_ harness: String, network: AgentNetwork, worktree: Bool, manualFlag: String? = nil) -> [String] {
        // --quiet: the pane shows the agent, and paddock's own notes (the
        // backend, the hooks and MCP servers it left out) stay out of it.
        // Errors still show.
        var args = ["run", "--quiet", harness, "--network", network.rawValue]
        if worktree { args.append("--worktree") }
        if let manualFlag { args.append(manualFlag) }
        return args
    }

    public static func stop(_ id: String) -> [String] { ["stop", id] }

    /// `view ID --write`: attach to the run with the keyboard.
    public static func view(_ id: String) -> [String] { ["view", id, "--write"] }

    /// `approvals answer ID once|session|deny`.
    public static func answer(_ id: String, _ answer: AgentAnswer) -> [String] {
        ["approvals", "answer", id, answer.rawValue]
    }
}

/// The answers of an agent request card: No, Yes once, Yes for this session.
public enum AgentAnswer: String, CaseIterable, Equatable, Sendable {
    case deny
    case once
    case session

    public var title: UIText {
        switch self {
        case .deny: return UIText("No")
        case .once: return UIText("Yes once")
        case .session: return UIText("Yes for this session")
        }
    }
}

/// The process of a terminal pane: what to run, with which arguments, in
/// which folder, with which environment.
public struct AgentCommand: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var directory: String?
    /// `NAME=VALUE` entries.
    public var environment: [String]

    public init(executable: String, args: [String], directory: String?, environment: [String]) {
        self.executable = executable
        self.args = args
        self.directory = directory
        self.environment = environment
    }

    /// The shells that take `-l -c SCRIPT ARG0 ARGS…`.
    static let posixShells: Set<String> = ["zsh", "bash", "sh", "ksh", "dash"]

    /// paddock with `args`, through the user's login shell, so the agent
    /// finds the commands of the user's PATH as in Terminal. An app that
    /// starts from the Dock gets only the system PATH. A shell that is not
    /// POSIX, such as fish, is replaced by zsh, the shell of macOS.
    public static func paddock(_ paddock: String, args: [String], directory: String?,
                               environment base: [String: String]) -> AgentCommand {
        let shell = base["SHELL"].flatMap { path -> String? in
            let name = (path as NSString).lastPathComponent
            return posixShells.contains(name) && path.hasPrefix("/") ? path : nil
        } ?? "/bin/zsh"
        return AgentCommand(executable: shell,
                            args: ["-l", "-c", #"exec "$0" "$@""#, paddock] + args,
                            directory: directory,
                            environment: AgentCommand.environment(base))
    }

    /// paddock with `args`, started as it is. For an environment that
    /// already is the one of the user's shell (`ShellEnvironment`): a
    /// second shell would only read its start files again and add to it.
    public static func direct(_ paddock: String, args: [String], directory: String?,
                              environment base: [String: String]) -> AgentCommand {
        AgentCommand(executable: paddock, args: args, directory: directory, environment: AgentCommand.environment(base))
    }

    /// The environment of the pane: the launcher's own, with a terminal
    /// type that SwiftTerm draws and a UTF-8 locale.
    public static func environment(_ base: [String: String]) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.keys.sorted().map { "\($0)=\(env[$0]!)" }
    }
}

/// "Open in Terminal": a `.command` file that Terminal, or the user's own
/// terminal app for `.command` files, runs. It runs `paddock view ID
/// --write` and removes itself.
public enum TerminalHandoff {
    public static func script(paddock: String, id: String) -> String {
        let command = ([paddock] + AgentArgs.view(id)).map(quote).joined(separator: " ")
        return """
        #!/bin/sh
        # paddock for Mac: the view of an agent run. This file removes itself.
        rm -f -- "$0"
        exec \(command)

        """
    }

    /// The file name: `paddock-view-1a2b3c.command`.
    public static func fileName(id: String) -> String {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "paddock-view-\(safe.isEmpty ? "run" : safe).command"
    }

    /// A word for `/bin/sh`: in single quotes unless it is plain.
    static func quote(_ word: String) -> String {
        let plain = !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@".contains($0) }
        return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
