import Foundation

/// The steps of the welcome window, in order. The flow leads to the first
/// agent at work. No step is about the base image of the Mac apps: that
/// step is in the Apps section (`LauncherStore.addNeedsBaseImage`).
public enum WelcomeStep: Int, CaseIterable, Equatable, Sendable {
    case welcome = 1
    case check
    case start

    public var title: UIText {
        switch self {
        case .welcome: return UIText("Welcome")
        case .check: return UIText("Check this Mac")
        case .start: return UIText("Start your first agent")
        }
    }

    /// The step with this number, or the nearest one.
    public static func at(_ number: Int) -> WelcomeStep {
        WelcomeStep(rawValue: min(max(number, WelcomeStep.welcome.rawValue), WelcomeStep.start.rawValue)) ?? .welcome
    }
}

/// The fixed texts of step 1. The story is "your computer stays yours".
/// It does not lead with auto-approval. Each line says what paddock does:
///
/// - `approve`: a run in manual mode asks before it runs a command or
///   changes a file (`AgentMode.manual`), the default; full auto is the
///   other choice of step 3, an opt-in.
/// - `room`: the sandbox sees the project, a private home folder and the
///   package caches. It never sees the real home folder, `~/.ssh`, cloud
///   credentials or other projects.
/// - `copy`: with "Work in a new branch" (`paddock run --worktree`) the
///   agent works in its own copy of a git project, and you review its
///   changes before they reach your branch. The option is off until you
///   turn it on, so the line says "can".
/// - `apps`: `paddock app` runs a Mac app in a sandbox of its own.
public enum WelcomeCopy {
    public static let title = UIText("Your computer stays yours")
    public static let approve = UIText("Use your coding agent as usual. It asks you before each step, or it works on its own when you choose that.")
    public static let room = UIText("Each agent lives in its own room. It cannot reach your keys or your other projects.")
    public static let copy = UIText("In a git project, the agent can work on a copy. You decide what goes back.")
    public static let apps = UIText("Your Mac apps can get rooms too. You can add them later.")

    /// The three points of step 1, in order.
    public static let points = [approve, room, copy]

    /// Step 2, when the user's shell gave no environment: one line.
    public static let shellFallback = UIText("Your shell did not answer, so paddock for Mac uses the usual folders.")
    /// Step 2, under the agents that paddock did not find.
    public static let lookAgain = UIText("After you install an agent, click Look again.")
}

/// The words of Settings for the shell whose PATH the launcher uses.
public enum ShellCopy {
    public static func status(_ source: LauncherEnvironment.Source) -> UIText {
        switch source {
        case .shell(let path): return UIText("paddock for Mac finds the agents with the PATH of %@.", path)
        case .fallback: return WelcomeCopy.shellFallback
        case .inherited: return UIText("paddock for Mac did not ask a shell. It uses its own PATH.")
        }
    }
}

/// One agent of step 2: paddock's entry, the character and, for an agent
/// that is not installed, how to install it.
public struct AgentCheck: Equatable, Sendable, Identifiable {
    public var harness: String
    public var title: String
    public var color: CharacterColor
    public var installed: Bool
    /// The command that installs the agent, when the launcher knows one.
    public var install: String?
    /// Where paddock found the agent: `exe` of `paddock list --json`.
    public var path: String?

    public init(harness: String, title: String, color: CharacterColor, installed: Bool, install: String? = nil,
                path: String? = nil) {
        self.harness = harness
        self.title = title
        self.color = color
        self.installed = installed
        self.install = install
        self.path = path
    }

    public var id: String { harness }

    /// The path for the row: `~/.local/bin/claude`.
    public func shownPath(home: String) -> String? {
        path.map { Format.tildePath($0, home: home) }
    }

    public var result: UIText {
        if installed { return UIText("Installed") }
        if install != nil { return UIText("Not installed. Run this command in Terminal:") }
        return UIText("Not installed. Install it in Terminal.")
    }

    /// The spoken state of the mark at the end of the row.
    public var mark: UIText { installed ? UIText("Installed") : UIText("Not installed") }
}

/// The install command of each agent that the launcher knows, as its
/// maker documents it. The command of the profile in paddock's list wins
/// when paddock gives one.
public enum AgentInstall {
    public static func command(_ harness: String) -> String? {
        switch harness.lowercased() {
        case "claude": return "npm install -g @anthropic-ai/claude-code"
        case "codex": return "npm install -g @openai/codex"
        case "gemini": return "npm install -g @google/gemini-cli"
        case "copilot": return "npm install -g @github/copilot"
        case "opencode": return "npm install -g opencode-ai"
        case "amp": return "npm install -g @sourcegraph/amp"
        case "qwen": return "npm install -g @qwen-code/qwen-code"
        case "kilo": return "npm install -g @kilocode/cli"
        case "pi": return "npm install -g @mariozechner/pi-coding-agent"
        case "openclaw": return "npm install -g openclaw"
        case "crush": return "npm install -g @charmland/crush"
        default: return nil
        }
    }
}

/// The checklist of welcome step 2: paddock, the agents and the free
/// space. It does not run `paddock doctor`: those checks are for the Mac
/// apps and show with the base image step.
public enum WelcomeChecks {
    /// `v1` of `paddock.mac-launcher/v1`.
    public static var protocolVersion: String {
        LauncherProtocol.name.split(separator: "/").last.map(String.init) ?? LauncherProtocol.name
    }

    /// The paddock row: the version and the launcher protocol once both
    /// passed, else what `Prerequisites` says of the binary.
    public static func paddockRow(binary: VersionGate.Verdict?, missing: Bool) -> PrereqRow {
        if !missing, case .ok(let version)? = binary {
            return PrereqRow(kind: .paddock, status: .pass, title: Prerequisites.title(.paddock),
                             result: UIText("paddock %@ found, launcher protocol %@", version, protocolVersion),
                             actions: [])
        }
        return Prerequisites.paddockRow(binary: binary, missing: missing)
    }

    /// The agents of `paddock list --json`: the installed ones first, each
    /// group in the order of the New Agent sheet. Desktop apps are out.
    public static func agents(_ harnesses: [HarnessJSON]) -> [AgentCheck] {
        let sorted = AgentCharacter.sorted(harnesses.filter { !$0.app })
        let checks = sorted.map { h in
            AgentCheck(harness: h.name, title: AgentCharacter.title(h.name, summary: h.summary),
                       color: AgentCharacter.color(h.name), installed: h.installed,
                       install: h.installed ? nil : (h.install ?? AgentInstall.command(h.name)),
                       path: h.installed ? h.exe : nil)
        }
        return checks.filter(\.installed) + checks.filter { !$0.installed }
    }

    /// The free space row. It never fails: an agent needs no fixed amount.
    public static func spaceRow(free: Int64) -> PrereqRow {
        PrereqRow(kind: .space, status: .pass, title: Prerequisites.title(.space),
                  result: UIText("%@ free on this disk", Format.gb(free)), actions: [])
    }

    /// Continue is on once paddock passed. A Mac with no agent installed
    /// can go on: step 3 says what is missing, and "Skip for now" is there.
    public static func canContinue(_ paddock: PrereqRow) -> Bool {
        paddock.status == .pass
    }
}
