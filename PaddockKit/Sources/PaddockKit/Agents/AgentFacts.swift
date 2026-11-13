import Foundation

// The facts of a run that a newer paddock gives, besides `ps` and `board`:
// the notes of the run (`run_notes` in `ps --json`, paddock 0.2.4), the
// unread questions of its mailbox (`unread_ask` of `mail ls --json`), the
// commits of its loft (`loft_commits` of `board --json`) and its device
// calls (`kind: "device_call"` events). An older paddock has none of them:
// each reader then gives nil, and the page shows nothing in its place.

// MARK: - The notes of a run

/// One note of paddock about a run: the lines that `--quiet` keeps out of
/// the pane. `{"level":"warning","text":"…"}`.
public struct RunNote: Equatable, Sendable, Hashable {
    public enum Level: String, CaseIterable, Equatable, Sendable {
        case error, ask, warning, info

        /// paddock's word. An unknown word is a plain note.
        public static func of(_ word: String?) -> Level {
            switch word?.lowercased() {
            case "error", "err", "fatal": return .error
            case "ask", "question": return .ask
            case "warning", "warn": return .warning
            default: return .info
            }
        }

        /// The title of the group on the Details tab.
        public var title: UIText {
            switch self {
            case .error: return UIText("Errors")
            case .ask: return UIText("Questions")
            case .warning: return UIText("Warnings")
            case .info: return UIText("Notes")
            }
        }

        /// The SF Symbol and its tint of the group.
        public var symbol: (name: String, tint: SymbolTint) {
            switch self {
            case .error: return ("xmark.octagon.fill", .red)
            case .ask: return ("questionmark.bubble.fill", .orange)
            case .warning: return ("exclamationmark.triangle.fill", .orange)
            case .info: return ("info.circle", .secondary)
            }
        }
    }

    public var level: Level
    /// paddock's words, as it wrote them.
    public var text: String

    public init(level: Level, text: String) {
        self.level = level
        self.text = text
    }

    /// The notes of `run_notes`, or nil when the field is not there: an
    /// older paddock. A note with no text is left out.
    static func list(_ value: JSONValue?) -> [RunNote]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap { item -> RunNote? in
            switch item {
            case .object(let raw):
                let fields = JSONFields(raw)
                guard let text = fields.string("text", "message", "line")?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return RunNote(level: Level.of(fields.string("level", "kind")), text: text)
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : RunNote(level: .info, text: trimmed)
            default:
                return nil
            }
        }
    }
}

/// The notes of a run in groups, as the Details tab shows them.
public enum RunNotes {
    public struct Group: Equatable, Sendable, Identifiable {
        public var level: RunNote.Level
        public var notes: [RunNote]
        public var id: String { level.rawValue }
    }

    /// One group per level that has notes: errors first, then questions,
    /// warnings and plain notes. In a group the notes keep paddock's order.
    public static func grouped(_ notes: [RunNote]?) -> [Group] {
        guard let notes else { return [] }
        return RunNote.Level.allCases.compactMap { level in
            let mine = notes.filter { $0.level == level }
            return mine.isEmpty ? nil : Group(level: level, notes: mine)
        }
    }
}

// MARK: - The mailbox: paddock mail ls --json

/// `paddock mail ls --json`: the runs that have a mailbox. paddock 0.2.3
/// writes a list; a newer one gives each run `unread_ask`, the questions
/// of the agent that you did not read. The reader takes a list, or an
/// object with the list in `runs` or `mailboxes`.
public enum MailboxJSON {
    /// The unread questions by run id. A run with no `unread_ask` is not
    /// in it: that paddock does not say, and the room shows no mailbox.
    public static func unreadAsks(_ data: Data) throws -> [String: Int] {
        let top = try StrictJSON.parse(data)
        var items: [JSONValue] = []
        switch top {
        case .array(let list): items = list
        case .object(let raw):
            let fields = JSONFields(raw)
            if let version = fields.string("api_version"), !version.hasPrefix("paddock.mail") {
                throw CommandError.badJSON(output: version)
            }
            if case .array(let list)? = fields.value("runs", "mailboxes") { items = list }
        default:
            throw CommandError.badJSON(output: String(decoding: data.prefix(200), as: UTF8.self))
        }
        var out: [String: Int] = [:]
        for item in items {
            guard let fields = JSONFields(item),
                  let id = fields.string("run", "id", "run_id", "sandbox"),
                  let asks = fields.int("unread_ask") else { continue }
            out[id] = max(0, asks)
        }
        return out
    }
}

// MARK: - Device calls: the event stream

/// A call of a run to a device of /dev/paddock: `{"v":1,"kind":
/// "device_call","sandbox":"…","device":"camera","covered":false}`. A
/// covered socket waits for your answer.
public struct DeviceCallEvent: Equatable, Sendable {
    /// The run that called.
    public var run: String
    public var device: String?
    public var covered: Bool

    public init(run: String, device: String? = nil, covered: Bool = false) {
        self.run = run
        self.device = device
        self.covered = covered
    }

    static func decode(_ data: Data) -> DeviceCallEvent? {
        guard let fields = JSONFields(try? StrictJSON.parse(data)),
              let run = fields.string("sandbox", "run", "run_id", "id") else { return nil }
        var covered = fields.bool("covered") ?? false
        switch fields.string("state", "status")?.lowercased() {
        case "ask"?, "asked"?, "waiting"?, "covered"?, "pending"?: covered = true
        default: break
        }
        return DeviceCallEvent(run: run, device: fields.string("device", "name"), covered: covered)
    }
}

/// The device calls of one run so far, for its cable.
public struct DeviceCalls: Equatable, Sendable {
    public var calls: Int
    /// The state of the last call: its socket is covered.
    public var covered: Bool
    /// The device of the last call.
    public var device: String?

    public init(calls: Int = 0, covered: Bool = false, device: String? = nil) {
        self.calls = calls
        self.covered = covered
        self.device = device
    }

    /// The cable of the motion layer.
    public var world: RoomWorld.Device { RoomWorld.Device(calls: calls, covered: covered) }
}

/// Run ids: a full id and its short form (at least 6 characters) name the
/// same run, as for the request cards.
enum RunID {
    static func same(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return min(a.count, b.count) >= 6 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    /// The value of `id` in `values`, by its full id or a short form.
    static func find<V>(_ id: String?, in values: [String: V]) -> V? {
        guard let id else { return nil }
        if let value = values[id] { return value }
        return values.first { same($0.key, id) }?.value
    }
}
