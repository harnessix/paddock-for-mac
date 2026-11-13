import Foundation

/// The state of one agent run, as the TUI and the board name them.
public enum AgentState: Equatable, Sendable {
    /// The launcher started the run; paddock does not list it yet.
    case starting
    /// The agent works.
    case working
    /// Requests of the agent wait for you: the count.
    case waiting(Int)
    /// The agent is at its prompt and nothing is new.
    case idle
    /// The screen did not change for a while, or mail waits unread.
    case stuck
    /// The run ended. `done` when its last status was `done:`.
    case ended(done: Bool)
    /// The run failed or is blocked: paddock's line, when it gave one.
    case failed(String?)

    /// True while the run is there: it can be stopped.
    public var isLive: Bool {
        switch self {
        case .starting, .working, .waiting, .idle, .stuck: return true
        case .ended, .failed: return false
        }
    }

    /// The order of the rooms: what needs you first, as on the board.
    public var urgency: Int {
        switch self {
        case .waiting: return 0
        case .failed: return 1
        case .stuck: return 2
        case .working: return 3
        case .starting: return 4
        case .idle: return 5
        case .ended(let done): return done ? 6 : 7
        }
    }

    /// The character's loop: work, wait (with the "!" bubble), idle,
    /// sleep after the end, blocked on a failure.
    public var pose: CharacterPose {
        switch self {
        case .working: return .work
        case .waiting: return .wait
        case .starting, .idle, .stuck: return .idle
        case .ended: return .sleep
        case .failed: return .blocked
        }
    }

    /// The state word of the pill and the sidebar row.
    public var word: UIText {
        switch self {
        case .starting: return UIText("Starting")
        case .working: return UIText("Working")
        case .waiting: return UIText("Waiting for you")
        case .idle: return UIText("Idle")
        case .stuck: return UIText("Stuck")
        case .ended(let done): return done ? UIText("Done") : UIText("Ended")
        case .failed: return UIText("Failed")
        }
    }

    /// The SF Symbol and its tint of the pill.
    public var symbol: (name: String, tint: SymbolTint) {
        switch self {
        case .starting: return ("hourglass", .secondary)
        case .working: return ("play.circle.fill", .green)
        case .waiting: return ("exclamationmark.bubble.fill", .orange)
        case .idle: return ("pause.circle", .secondary)
        case .stuck: return ("tortoise.fill", .orange)
        case .ended(let done): return (done ? "checkmark.circle" : "moon.zzz", .secondary)
        case .failed: return ("exclamationmark.octagon.fill", .red)
        }
    }

    /// The line under the name: the word, and the request count or
    /// paddock's line of a failure.
    public var line: UIText {
        switch self {
        case .waiting(let count):
            return count == 1 ? UIText("Waiting for you · 1 request")
                : UIText("Waiting for you · %lld requests", count)
        case .failed(let reason?):
            return UIText("Failed · %@", UIText.cli(reason, else: StatusPresentation.seeDetails))
        default:
            return word
        }
    }
}

/// The character of an agent: its color follows the harness.
public enum AgentCharacter {
    /// orange claude, blue codex, purple gemini, green copilot, pink grok,
    /// teal opencode, gray for the others.
    public static func color(_ harness: String) -> CharacterColor {
        switch harness.lowercased() {
        case "claude": return .orange
        case "codex": return .blue
        case "gemini": return .purple
        case "copilot": return .green
        case "grok": return .pink
        case "opencode": return .teal
        default: return .gray
        }
    }

    /// The name people know the harness by. paddock's description is the
    /// fallback: `Anthropic Claude Code` is long for a card.
    public static func title(_ harness: String, summary: String? = nil) -> String {
        switch harness.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "copilot": return "Copilot CLI"
        case "grok": return "Grok"
        case "opencode": return "opencode"
        default: return summary ?? harness
        }
    }

    /// The order of the agent grid of the sheet: the six known harnesses
    /// first, then the others by name.
    public static let known = ["claude", "codex", "gemini", "copilot", "grok", "opencode"]

    public static func sorted(_ harnesses: [HarnessJSON]) -> [HarnessJSON] {
        harnesses.sorted { a, b in
            let x = known.firstIndex(of: a.name) ?? known.count
            let y = known.firstIndex(of: b.name) ?? known.count
            if x != y { return x < y }
            return a.name < b.name
        }
    }
}

/// The state of a run from what paddock says about it.
public enum AgentStateMapper {
    /// The board's word to a state. Unknown words are nil.
    public static func board(_ word: String, status: String? = nil, requests: Int = 0) -> AgentState? {
        switch word.lowercased() {
        case "waiting": return .waiting(max(1, requests))
        case "blocked": return .failed(status.map(AgentStateMapper.reason) ?? nil)
        case "stuck": return .stuck
        case "working": return .working
        case "idle": return .idle
        case "done": return .ended(done: true)
        case "ended": return .ended(done: false)
        default: return nil
        }
    }

    /// The state of a running sandbox. Requests win, then the board, then
    /// the fields of `ps`: `stuck`, `idle_since`, else it works.
    public static func running(_ run: AgentRunJSON, board: BoardRunJSON?, requests: Int) -> AgentState {
        if requests > 0 { return .waiting(requests) }
        if let board, let state = AgentStateMapper.board(board.state, status: board.status) {
            // A run that ps still lists has not ended, whatever the board
            // read a moment before said.
            if case .ended = state { return .idle }
            if case .waiting = state { return .waiting(1) }
            return state
        }
        if run.stuck { return .stuck }
        if run.idleSince != nil { return .idle }
        return .working
    }

    /// The state of an ended run: failed with a non-zero exit or a
    /// `blocked:` status, done with a `done:` status, else ended.
    public static func ended(_ run: EndedRunJSON, board: BoardRunJSON?) -> AgentState {
        if let board, let state = AgentStateMapper.board(board.state, status: board.status) {
            switch state {
            case .failed, .ended: return state
            default: break
            }
        }
        if let reason = run.reason?.lowercased() {
            if reason.hasPrefix("blocked:") { return .failed(AgentStateMapper.reason(run.reason ?? "")) }
            if reason.hasPrefix("done:") { return .ended(done: true) }
        }
        if let code = run.exitCode, code != 0 {
            return .failed(run.reason)
        }
        return .ended(done: false)
    }

    /// The state of a terminal pane whose run paddock does not list: it
    /// starts, or its process ended with `exit`. A pane that you stopped
    /// ended, whatever its exit status (SIGTERM is 143).
    public static func pane(exit: Int32?, running: Bool, stopped: Bool = false) -> AgentState {
        if running { return .starting }
        guard let exit, !stopped else { return .ended(done: false) }
        return exit == 0 ? .ended(done: false) : .failed(nil)
    }

    /// `blocked: no network` → `no network`.
    static func reason(_ status: String) -> String? {
        var text = status.trimmingCharacters(in: .whitespaces)
        for prefix in ["blocked:", "done:"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? nil : text
    }
}
