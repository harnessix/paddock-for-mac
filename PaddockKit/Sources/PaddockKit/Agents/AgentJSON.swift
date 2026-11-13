import Foundation

// The JSON of the terminal agents: `paddock list --json`, `recent --json`,
// `ps --json`, `board --json`, and the agent cards of `approvals --json`.
//
// Only the card fields of `approvals --json` and the top level of the
// other commands are known from real output (Fixtures/base). The fields of
// one run in `ps --json` and `board --json` come from paddock's own help
// text. The readers below are lenient: an absent field is nil, a field of
// another type is nil, and a time is Unix seconds or ISO 8601 text. The
// names that no fixture shows are guesses.

/// A time in paddock's JSON: Unix seconds, Unix milliseconds or ISO 8601.
public enum PaddockTime {
    public static func date(_ value: JSONValue?) -> Date? {
        switch value {
        case .number(let text)?:
            guard let number = Double(text), number > 0 else { return nil }
            // Milliseconds are past the year 5000 as seconds.
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        case .string(let text)?:
            return iso(text) ?? Double(text).flatMap { date(.number(String($0))) }
        default:
            return nil
        }
    }

    public static func iso(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

/// One JSON object, read by name. `JSONValue` keeps the snake_case keys of
/// paddock as they are.
public struct JSONFields: Equatable, Sendable {
    public var fields: [String: JSONValue]

    public init(_ fields: [String: JSONValue]) {
        self.fields = fields
    }

    public init?(_ value: JSONValue?) {
        guard case .object(let fields)? = value else { return nil }
        self.fields = fields
    }

    /// The first of `keys` that holds a value other than null.
    public func value(_ keys: String...) -> JSONValue? { first(keys) }

    func first(_ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = fields[key], value != .null { return value }
        }
        return nil
    }

    /// Text of the first key with a string. A number is text too: an id
    /// can be a number.
    public func string(_ keys: String...) -> String? {
        switch first(keys) {
        case .string(let text)?: return text.isEmpty ? nil : text
        case .number(let text)?: return text
        default: return nil
        }
    }

    public func int(_ keys: String...) -> Int? {
        switch first(keys) {
        case .number(let text)?: return Int(text) ?? Double(text).map { Int($0) }
        case .string(let text)?: return Int(text)
        default: return nil
        }
    }

    public func bool(_ keys: String...) -> Bool? {
        if case .bool(let flag)? = first(keys) { return flag }
        return nil
    }

    public func date(_ keys: String...) -> Date? {
        PaddockTime.date(first(keys))
    }

    public func strings(_ keys: String...) -> [String]? {
        guard case .array(let items)? = first(keys) else { return nil }
        return items.compactMap { item -> String? in
            if case .string(let text) = item { return text }
            return nil
        }
    }

    public func objects(_ keys: String...) -> [JSONFields] {
        guard case .array(let items)? = first(keys) else { return [] }
        return items.compactMap { JSONFields($0) }
    }
}

/// Reads one paddock answer as a JSON object. The strict reader refuses a
/// key twice and text after the value, as for the launcher protocol.
enum AgentDecode {
    static func object(_ data: Data) throws -> JSONFields {
        guard let fields = JSONFields(try StrictJSON.parse(data)) else {
            throw CommandError.badJSON(output: String(decoding: data.prefix(200), as: UTF8.self))
        }
        return fields
    }
}

// MARK: - paddock list --json

/// One harness of `paddock list --json`: `{"name":"claude","description":
/// "Anthropic Claude Code","exe":"/…/claude","installed":true,"app":false}`.
public struct HarnessJSON: Equatable, Sendable, Identifiable {
    public var name: String
    /// paddock's line: `Anthropic Claude Code`.
    public var summary: String?
    public var exe: String?
    public var installed: Bool
    /// True for a desktop app (`paddock app`), not a terminal agent.
    public var app: Bool
    /// The install command of the profile, one line for Terminal. nil
    /// when paddock does not give one: paddock 0.2.3 and older never do.
    public var install: String?

    public var id: String { name }

    public init(name: String, summary: String? = nil, exe: String? = nil, installed: Bool, app: Bool = false,
                install: String? = nil) {
        self.name = name
        self.summary = summary
        self.exe = exe
        self.installed = installed
        self.app = app
        self.install = install
    }

    init?(_ fields: JSONFields) {
        guard let name = fields.string("name") else { return nil }
        self.init(name: name, summary: fields.string("description"), exe: fields.string("exe"),
                  installed: fields.bool("installed") ?? false, app: fields.bool("app") ?? false,
                  install: HarnessJSON.install(fields))
    }

    /// The install command of a harness: a string under `install`,
    /// `install_command` or `install_hint`, or an object there with a
    /// `command`. Only the first line counts.
    static func install(_ fields: JSONFields) -> String? {
        let keys = ["install", "install_command", "install_hint"]
        let text = keys.lazy.compactMap { key -> String? in
            fields.string(key) ?? JSONFields(fields.value(key))?.string("command", "cmd")
        }.first
        guard let line = text?.split(whereSeparator: \.isNewline).first else { return nil }
        let clean = line.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    /// The harnesses of the answer. `api_version` must be paddock.list/v1.
    public static func list(_ data: Data) throws -> [HarnessJSON] {
        let top = try AgentDecode.object(data)
        if let version = top.string("api_version"), !version.hasPrefix("paddock.list/") {
            throw CommandError.badJSON(output: version)
        }
        return top.objects("harnesses").compactMap(HarnessJSON.init)
    }
}

// MARK: - paddock recent --json

/// One project of `paddock recent --json`. The real answer seen so far has
/// an empty list; an item is a path, or an object with the path.
public struct RecentProjectJSON: Equatable, Sendable, Identifiable {
    public var path: String
    /// The harness of the last run there, when paddock names it.
    public var harness: String?
    public var last: Date?

    public var id: String { path }

    public init(path: String, harness: String? = nil, last: Date? = nil) {
        self.path = path
        self.harness = harness
        self.last = last
    }

    public static func list(_ data: Data) throws -> [RecentProjectJSON] {
        let top = try AgentDecode.object(data)
        guard case .array(let items)? = top.value("projects") else { return [] }
        var seen = Set<String>()
        var out: [RecentProjectJSON] = []
        for item in items {
            var project: RecentProjectJSON?
            switch item {
            case .string(let path): project = RecentProjectJSON(path: path)
            case .object(let raw):
                let fields = JSONFields(raw)
                if let path = fields.string("path", "project", "dir", "root") {
                    project = RecentProjectJSON(path: path,
                                                harness: fields.string("harness") ?? fields.strings("harnesses")?.first,
                                                last: fields.date("last", "last_used", "time", "at", "started"))
                }
            default: break
            }
            if let project, seen.insert(project.path).inserted { out.append(project) }
        }
        return out
    }
}

// MARK: - paddock ps --json

/// One running sandbox of `paddock ps --json` (`sandboxes`).
public struct AgentRunJSON: Equatable, Sendable, Identifiable {
    public var id: String
    public var harness: String
    /// The project folder of the run.
    public var project: String?
    /// The branch of a `--worktree` run.
    public var branch: String?
    public var started: Date?
    /// `none`, `api`, `egress` or `host`.
    public var network: String?
    public var pid: Int?
    /// The last line of the view log, at most 120 characters.
    public var activity: String?
    /// Set while a detached run waits for input.
    public var idleSince: Date?
    /// True when paddock found the screen unchanged for `stuck_after`.
    public var stuck: Bool
    /// The project files that the run changed, when paddock says.
    public var filesChanged: Int?
    /// The changed files by name, when paddock lists them.
    public var files: [String]?
    /// The id of the parent run of a spawned child.
    public var parent: String?
    /// `auto` or `manual`: how the agent works. Newer paddock only.
    public var approvals: String?
    /// The notes of `run_notes` (paddock 0.2.4): the lines that `--quiet`
    /// keeps out of the pane. Nil with an older paddock.
    public var notes: [RunNote]?

    public init(id: String, harness: String, project: String? = nil, branch: String? = nil, started: Date? = nil,
                network: String? = nil, pid: Int? = nil, activity: String? = nil, idleSince: Date? = nil,
                stuck: Bool = false, filesChanged: Int? = nil, files: [String]? = nil, parent: String? = nil,
                approvals: String? = nil, notes: [RunNote]? = nil) {
        self.id = id
        self.harness = harness
        self.project = project
        self.branch = branch
        self.started = started
        self.network = network
        self.pid = pid
        self.activity = activity
        self.idleSince = idleSince
        self.stuck = stuck
        self.filesChanged = filesChanged
        self.files = files
        self.parent = parent
        self.approvals = approvals
        self.notes = notes
    }

    init?(_ fields: JSONFields) {
        guard let id = fields.string("id", "sandbox_id", "sandbox"),
              let harness = fields.string("harness") else { return nil }
        var stuck = false
        switch fields.value("stuck") {
        case .bool(let flag)?: stuck = flag
        case .object?, .string?: stuck = true
        default: break
        }
        // `files` may be a count, a list of names or an object of lists.
        var count: Int?
        var names: [String]?
        switch fields.value("files_changed", "changed_files", "uncommitted", "files") {
        case .number(let text)?: count = Int(text)
        case .array(let items)?:
            names = items.compactMap { item -> String? in
                switch item {
                case .string(let path): return path
                case .object(let raw): return JSONFields(raw).string("path", "file", "name")
                default: return nil
                }
            }
            count = items.count
        default: break
        }
        self.init(id: id, harness: harness,
                  project: fields.string("project", "path", "cwd", "dir"),
                  branch: fields.string("branch", "worktree_branch"),
                  started: fields.date("started", "start", "created", "since"),
                  network: fields.string("network", "network_mode"),
                  pid: fields.int("pid"),
                  activity: fields.string("activity"),
                  idleSince: fields.date("idle_since"),
                  stuck: stuck, filesChanged: count, files: names,
                  parent: fields.string("parent", "parent_id"),
                  approvals: fields.string("approvals"),
                  notes: RunNote.list(fields.value("run_notes")))
    }
}

/// One run of `ended` in `paddock ps --json`.
public struct EndedRunJSON: Equatable, Sendable, Identifiable {
    public var id: String
    public var harness: String
    public var project: String?
    public var branch: String?
    public var started: Date?
    public var ended: Date?
    public var exitCode: Int?
    /// paddock's reason or last status line.
    public var reason: String?
    /// The notes of `run_notes`, as for a running sandbox.
    public var notes: [RunNote]?

    public init(id: String, harness: String, project: String? = nil, branch: String? = nil, started: Date? = nil,
                ended: Date? = nil, exitCode: Int? = nil, reason: String? = nil, notes: [RunNote]? = nil) {
        self.id = id
        self.harness = harness
        self.project = project
        self.branch = branch
        self.started = started
        self.ended = ended
        self.exitCode = exitCode
        self.reason = reason
        self.notes = notes
    }

    init?(_ fields: JSONFields) {
        guard let id = fields.string("id", "sandbox_id", "sandbox"),
              let harness = fields.string("harness") else { return nil }
        self.init(id: id, harness: harness,
                  project: fields.string("project", "path", "cwd", "dir"),
                  branch: fields.string("branch"),
                  started: fields.date("started", "start"),
                  ended: fields.date("ended", "ended_at", "exited", "stopped", "at"),
                  exitCode: fields.int("exit_code", "exit", "code"),
                  reason: fields.string("reason", "why", "status", "last"),
                  notes: RunNote.list(fields.value("run_notes")))
    }
}

/// `paddock ps --json`: `{"api_version":"paddock.ps/v1","sandboxes":[…],
/// "ended":[…],"shared_devices":[…]}`.
public struct PsJSON: Equatable, Sendable {
    public var sandboxes: [AgentRunJSON]
    public var ended: [EndedRunJSON]

    public init(sandboxes: [AgentRunJSON] = [], ended: [EndedRunJSON] = []) {
        self.sandboxes = sandboxes
        self.ended = ended
    }

    public static func decode(_ data: Data) throws -> PsJSON {
        let top = try AgentDecode.object(data)
        if let version = top.string("api_version"), !version.hasPrefix("paddock.ps/") {
            throw CommandError.badJSON(output: version)
        }
        return PsJSON(sandboxes: top.objects("sandboxes").compactMap(AgentRunJSON.init),
                      ended: top.objects("ended").compactMap(EndedRunJSON.init))
    }
}

// MARK: - paddock board --json

/// The state of one run on the board, the TUI's word: `waiting`,
/// `blocked`, `stuck`, `working`, `idle`, `done`, `ended`.
public struct BoardRunJSON: Equatable, Sendable {
    public var id: String
    public var state: String
    public var harness: String?
    /// The project path of the block the run is in.
    public var project: String?
    /// The last status line of the run: `blocked: no network`.
    public var status: String?
    public var since: Date?
    /// The commits of the loft of the run (`loft_commits`): the notes the
    /// agent wrote there. Nil when this paddock does not say.
    public var loftCommits: Int?

    public init(id: String, state: String, harness: String? = nil, project: String? = nil, status: String? = nil,
                since: Date? = nil, loftCommits: Int? = nil) {
        self.id = id
        self.state = state
        self.harness = harness
        self.project = project
        self.status = status
        self.since = since
        self.loftCommits = loftCommits
    }
}

/// `paddock board --json`, read for the state of each run.
public struct BoardJSON: Equatable, Sendable {
    public var approvalsWaiting: Int
    /// The runs by id.
    public var runs: [String: BoardRunJSON]

    public init(approvalsWaiting: Int = 0, runs: [String: BoardRunJSON] = [:]) {
        self.approvalsWaiting = approvalsWaiting
        self.runs = runs
    }

    public static func decode(_ data: Data) throws -> BoardJSON {
        let top = try AgentDecode.object(data)
        var runs: [String: BoardRunJSON] = [:]
        // The loft belongs to the repository: a project's count is the
        // count of each of its runs that gives none of its own.
        func add(_ item: JSONValue, fallbackState: String?, project: String?, loft: Int?) {
            switch item {
            case .string(let id):
                // A ticket line names its runs by id; the run has the
                // ticket's state.
                if let state = fallbackState, runs[id] == nil {
                    runs[id] = BoardRunJSON(id: id, state: state, project: project, loftCommits: loft)
                }
            case .object(let raw):
                let fields = JSONFields(raw)
                guard let id = fields.string("id", "run", "run_id", "sandbox"),
                      let state = fields.string("state") ?? fallbackState else { return }
                runs[id] = BoardRunJSON(id: id, state: state, harness: fields.string("harness"),
                                        project: fields.string("project", "path") ?? project,
                                        status: fields.string("status", "last", "why"),
                                        since: fields.date("since", "at"),
                                        loftCommits: fields.int("loft_commits") ?? loft)
            default:
                break
            }
        }
        for project in top.objects("projects") {
            let path = project.string("path", "project", "root")
            let loft = project.int("loft_commits")
            for ticket in project.objects("tickets") {
                if case .array(let items)? = ticket.value("runs") {
                    for item in items { add(item, fallbackState: ticket.string("state"), project: path, loft: loft) }
                }
            }
            if case .array(let items)? = project.value("runs_without_ticket", "runs") {
                for item in items { add(item, fallbackState: nil, project: path, loft: loft) }
            }
        }
        return BoardJSON(approvalsWaiting: top.int("approvals_waiting") ?? 0, runs: runs)
    }
}

// MARK: - The agent cards of paddock approvals --json

/// A request that an agent sent to the host and that waits for an answer:
/// a host command, a git push, a new server, a device. One `pending` item
/// of `paddock approvals --json` whose capability is not `connect`.
public struct AgentRequestJSON: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// The sandbox (run) id that asks.
    public var sandbox: String
    public var harness: String?
    public var project: String?
    /// `exec`, `push`, `fetch`, `open-url`, `device`, `clipboard-read`…
    public var capability: String
    /// paddock's one line: `run a host command`.
    public var summary: String?
    /// The command or the target, as paddock shows it.
    public var detail: String?
    /// The agent's reason, as it gave it with `--reason`.
    public var reason: String?
    public var created: Date?
    /// When the request times out; nil when it does not.
    public var expires: Date?
    public var sessionAllowed: Bool
    public var choices: [String]

    public init(id: String, sandbox: String, harness: String? = nil, project: String? = nil, capability: String,
                summary: String? = nil, detail: String? = nil, reason: String? = nil, created: Date? = nil,
                expires: Date? = nil, sessionAllowed: Bool = false, choices: [String] = []) {
        self.id = id
        self.sandbox = sandbox
        self.harness = harness
        self.project = project
        self.capability = capability
        self.summary = summary
        self.detail = detail
        self.reason = reason
        self.created = created
        self.expires = expires
        self.sessionAllowed = sessionAllowed
        self.choices = choices
    }

    private enum CodingKeys: String, CodingKey {
        case id, sandbox, harness, project, capability, summary, detail, reason, created, expires
        case sessionAllowed, choices, ageS
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sandbox = try values.decodeIfPresent(String.self, forKey: .sandbox) ?? ""
        harness = try? values.decodeIfPresent(String.self, forKey: .harness)
        project = try? values.decodeIfPresent(String.self, forKey: .project)
        capability = try values.decode(String.self, forKey: .capability)
        summary = try? values.decodeIfPresent(String.self, forKey: .summary)
        detail = try? values.decodeIfPresent(String.self, forKey: .detail)
        let reason = try? values.decodeIfPresent(String.self, forKey: .reason)
        self.reason = reason.flatMap { $0.isEmpty ? nil : $0 }
        // paddock writes Unix seconds; 0 is "no time".
        let created = (try? values.decodeIfPresent(Double.self, forKey: .created)) ?? nil
        self.created = created.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let expires = (try? values.decodeIfPresent(Double.self, forKey: .expires)) ?? nil
        self.expires = expires.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        sessionAllowed = (try? values.decodeIfPresent(Bool.self, forKey: .sessionAllowed)) ?? false
        choices = (try? values.decodeIfPresent([String].self, forKey: .choices)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sandbox, forKey: .sandbox)
        try values.encodeIfPresent(harness, forKey: .harness)
        try values.encodeIfPresent(project, forKey: .project)
        try values.encode(capability, forKey: .capability)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(detail, forKey: .detail)
        try values.encodeIfPresent(reason, forKey: .reason)
        try values.encodeIfPresent(created?.timeIntervalSince1970, forKey: .created)
        try values.encodeIfPresent(expires?.timeIntervalSince1970, forKey: .expires)
        try values.encode(sessionAllowed, forKey: .sessionAllowed)
        try values.encode(choices, forKey: .choices)
    }

    /// True when the request belongs to the run `id`: the same id, or one
    /// is the short form of the other (`1a2b3c`, at least 6 characters).
    public func belongs(to id: String) -> Bool {
        guard !sandbox.isEmpty, !id.isEmpty else { return false }
        if sandbox == id { return true }
        let short = min(sandbox.count, id.count)
        return short >= 6 && (id.hasPrefix(sandbox) || sandbox.hasPrefix(id))
    }
}
