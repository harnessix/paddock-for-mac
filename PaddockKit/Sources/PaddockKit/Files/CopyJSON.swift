import Foundation

// The JSON of the copy commands of paddock 0.2.4 (core `src/copy/json.rs`):
//
//   paddock.copies/v1    paddock changes --json
//   paddock.changes/v1   paddock changes RUN --json
//   paddock.backups/v1   paddock backups --json
//   paddock.pointer/v1   paddock pointer status --json
//   paddock.apply/v1, keep/v1, discard/v1, restore/v1, undo/v1
//
// Times are seconds since 1970, sizes are bytes. A field that does not
// apply is `null`, never missing: `CopyKeys` lists the keys of each
// object, and the contract test holds the fixtures to these lists.
//
// A reader here refuses another `api_version` and an object without its
// identity (a run without an id, a change without a path). Every other
// field that is null or of another type reads as nil: one odd value does
// not take the Files screen away.

/// The `api_version` of each answer.
public enum CopyAPI {
    public static let copies = "paddock.copies/v1"
    public static let changes = "paddock.changes/v1"
    public static let backups = "paddock.backups/v1"
    public static let pointer = "paddock.pointer/v1"
    public static let apply = "paddock.apply/v1"
    public static let keep = "paddock.keep/v1"
    public static let discard = "paddock.discard/v1"
    public static let restore = "paddock.restore/v1"
    public static let undo = "paddock.undo/v1"
}

/// The keys of each object of the contract, as `json.rs` writes them.
public enum CopyKeys {
    public static let run: Set<String> = [
        "id", "short", "harness", "project", "copy", "state", "started", "ended", "removed", "method", "shared",
        "in_place", "git", "files", "bytes", "store", "base", "carried",
    ]
    public static let entry: Set<String> = ["size", "mtime", "mode", "link"]
    public static let change: Set<String> = [
        "path", "kind", "state", "conflict", "conflict_text", "kept", "writing", "copy", "original", "text",
        "added", "removed", "merge",
    ]
    public static let counts: Set<String> = ["new", "changed", "deleted", "conflicts", "kept", "ready", "applied", "behind"]
    public static let changesDoc: Set<String> = [
        "api_version", "run", "pointer", "token", "counts", "changes", "applied", "behind", "special", "auto_apply",
    ]
    public static let copiesDoc: Set<String> = ["api_version", "runs"]
    /// A row of `paddock changes --json`: the run and its counts.
    public static let copiesRow: Set<String> = run.union(["counts"])
    public static let pointerPart: Set<String> = ["state", "text", "action", "ok", "store"]
    public static let pointerDoc: Set<String> = [
        "api_version", "project", "state", "text", "action", "ok", "pointer", "store", "encryption",
    ]
    public static let pointerFile: Set<String> = ["format", "store", "created"]
    public static let pointerStore: Set<String> = ["id", "dir", "original", "created", "runs", "copies", "backups", "size"]
    public static let storeSize: Set<String> = ["bytes", "kind"]
    public static let backup: Set<String> = [
        "id", "short", "kind", "words", "created", "run", "harness", "files", "paths", "bytes", "shared", "method",
        "full", "undone", "by_undo", "undoable",
    ]
    public static let snapshot: Set<String> = ["id", "short", "kind", "words", "created", "harness", "files", "bytes", "shared"]
    public static let backupsDoc: Set<String> = ["api_version", "project", "pointer", "backups", "snapshots"]
}

/// An answer that is not the contract: another `api_version`, or an
/// object without its identity.
public struct CopyContractError: Error, Equatable, Sendable {
    public var what: String

    public init(_ what: String) {
        self.what = what
    }
}

extension JSONFields {
    func int64(_ keys: String...) -> Int64? {
        switch first(keys) {
        case .number(let text)?: return Int64(text) ?? Double(text).map { Int64($0) }
        case .string(let text)?: return Int64(text)
        default: return nil
        }
    }

    /// Seconds since 1970. The copy commands give nothing else.
    func seconds(_ key: String) -> Date? {
        guard case .number(let text)? = fields[key], let value = Double(text), value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// True for a value that is there and is not `false`: a time, an id.
    func isSet(_ key: String) -> Bool {
        switch fields[key] {
        case nil, .null?, .bool(false)?: return false
        default: return true
        }
    }

    /// A path: text, as paddock writes a `Path`.
    func path(_ key: String) -> String? {
        if case .string(let text)? = fields[key], !text.isEmpty { return text }
        return nil
    }
}

enum CopyDecode {
    /// The top object of an answer whose `api_version` is `api`.
    static func top(_ data: Data, _ api: String) throws -> JSONFields {
        let top = try AgentDecode.object(data)
        guard top.string("api_version") == api else {
            throw CopyContractError("api_version is \(top.string("api_version") ?? "missing"), not \(api)")
        }
        return top
    }

    /// The paths of a list: text items, or objects with a `path`.
    static func paths(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { item -> String? in
            switch item {
            case .string(let text): return text
            case .object(let raw): return JSONFields(raw).string("path", "file", "name")
            default: return nil
            }
        }
    }
}

// MARK: - A run with a copy

/// `live`, `ended` or `removed`.
public enum CopyRunState: Equatable, Sendable {
    /// The agent still runs: the copy can change.
    case live
    case ended
    /// paddock removed the copy: nothing is left to apply.
    case removed
    case other(String)

    public init(_ word: String) {
        switch word {
        case "live": self = .live
        case "ended": self = .ended
        case "removed": self = .removed
        default: self = .other(word)
        }
    }

    public var word: String {
        switch self {
        case .live: return "live"
        case .ended: return "ended"
        case .removed: return "removed"
        case .other(let word): return word
        }
    }
}

/// One run with a copy (`run_doc`).
public struct CopyRun: Equatable, Sendable, Identifiable {
    public var id: String
    public var short: String
    public var harness: String
    /// Your folder: the original.
    public var project: String
    /// The folder of the copy.
    public var copy: String
    public var state: CopyRunState
    public var started: Date?
    public var ended: Date?
    /// When paddock removed the copy.
    public var removed: Date?
    /// How the copy was made: paddock's word, such as `clone`.
    public var method: String?
    /// True when the copy shares its blocks with the original.
    public var shared: Bool
    /// True for a run that works in the folder itself: it has no copy.
    public var inPlace: Bool
    public var git: JSONValue
    public var files: Int?
    public var bytes: Int64?
    public var store: String?
    public var base: JSONValue
    public var carried: JSONValue

    init(_ f: JSONFields) throws {
        guard let id = f.string("id") else { throw CopyContractError("a run has no id") }
        guard let project = f.path("project") else { throw CopyContractError("run \(id) has no project") }
        self.id = id
        short = f.string("short") ?? id
        harness = f.string("harness") ?? ""
        self.project = project
        copy = f.path("copy") ?? ""
        state = CopyRunState(f.string("state") ?? "")
        started = f.seconds("started")
        ended = f.seconds("ended")
        removed = f.seconds("removed")
        method = f.string("method")
        shared = f.bool("shared") ?? false
        inPlace = f.bool("in_place") ?? false
        git = f.fields["git"] ?? .null
        files = f.int("files")
        bytes = f.int64("bytes")
        store = f.string("store")
        base = f.fields["base"] ?? .null
        carried = f.fields["carried"] ?? .null
    }

    /// `shop` for `/Users/demo/src/shop`.
    public var projectName: String { (project as NSString).lastPathComponent }
}

/// The counts of a run (`counts_doc`).
public struct CopyCounts: Equatable, Sendable {
    public var new: Int
    public var changed: Int
    public var deleted: Int
    public var conflicts: Int
    public var kept: Int
    /// The changes that an apply writes now.
    public var ready: Int
    public var applied: Int
    public var behind: Int

    public init(new: Int = 0, changed: Int = 0, deleted: Int = 0, conflicts: Int = 0, kept: Int = 0, ready: Int = 0,
                applied: Int = 0, behind: Int = 0) {
        self.new = new
        self.changed = changed
        self.deleted = deleted
        self.conflicts = conflicts
        self.kept = kept
        self.ready = ready
        self.applied = applied
        self.behind = behind
    }

    init(_ f: JSONFields) {
        self.init(new: f.int("new") ?? 0, changed: f.int("changed") ?? 0, deleted: f.int("deleted") ?? 0,
                  conflicts: f.int("conflicts") ?? 0, kept: f.int("kept") ?? 0, ready: f.int("ready") ?? 0,
                  applied: f.int("applied") ?? 0, behind: f.int("behind") ?? 0)
    }

    /// Every change of the copy: new, changed and deleted files.
    public var total: Int { new + changed + deleted }
    /// The changes that wait for you: ready to apply, or in conflict.
    public var waiting: Int { ready + conflicts }
}

/// A row of `paddock changes --json`.
public struct CopyRunRow: Equatable, Sendable, Identifiable {
    public var run: CopyRun
    /// Nil when paddock could not read the copy.
    public var counts: CopyCounts?

    public var id: String { run.id }
}

/// `paddock changes --json`: every run with a copy.
public struct CopiesDoc: Equatable, Sendable {
    public var runs: [CopyRunRow]

    public static func decode(_ data: Data) throws -> CopiesDoc {
        let top = try CopyDecode.top(data, CopyAPI.copies)
        return CopiesDoc(runs: try top.objects("runs").map { row in
            CopyRunRow(run: try CopyRun(row), counts: JSONFields(row.fields["counts"]).map(CopyCounts.init))
        })
    }
}

// MARK: - One change

/// `new`, `changed` or `deleted`.
public enum ChangeKind: Equatable, Sendable {
    case new, changed, deleted
    case other(String)

    public init(_ word: String) {
        switch word {
        case "new": self = .new
        case "changed": self = .changed
        case "deleted": self = .deleted
        default: self = .other(word)
        }
    }
}

/// `open`, `kept` or `conflict`.
public enum ChangeState: Equatable, Sendable {
    /// Ready: an apply writes it.
    case open
    /// You keep it in the copy: an apply of all leaves it there.
    case kept
    /// The original changed too.
    case conflict
    case other(String)

    public init(_ word: String) {
        switch word {
        case "open": self = .open
        case "kept": self = .kept
        case "conflict": self = .conflict
        default: self = .other(word)
        }
    }
}

/// What a merge of a conflict gives: `clean` or `conflicts`.
public enum MergeState: String, Equatable, Sendable {
    case clean, conflicts
}

/// One side of a change (`entry_doc`). Null in the JSON when the file is
/// not on that side.
public struct FileEntry: Equatable, Sendable {
    public var size: Int64
    /// Nil for a symlink.
    public var mtime: Date?
    /// `0644`.
    public var mode: String
    /// The target of a symlink.
    public var link: String?

    public init(size: Int64, mtime: Date? = nil, mode: String = "0644", link: String? = nil) {
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.link = link
    }

    init?(_ value: JSONValue?) {
        guard let f = JSONFields(value) else { return nil }
        self.init(size: f.int64("size") ?? 0, mtime: f.seconds("mtime"), mode: f.string("mode") ?? "",
                  link: f.string("link"))
    }

    public var isExecutable: Bool {
        guard let bits = Int(mode, radix: 8) else { return false }
        return bits & 0o111 != 0
    }
}

/// One change (`change_doc`).
public struct FileChange: Equatable, Sendable, Identifiable {
    /// The path from the project folder, with `/`.
    public var path: String
    public var kind: ChangeKind
    public var state: ChangeState
    /// The kind of the conflict: paddock's word.
    public var conflict: String?
    /// paddock's sentence for the conflict.
    public var conflictText: String?
    public var kept: Bool
    /// True while the agent writes the file.
    public var writing: Bool
    public var copy: FileEntry?
    public var original: FileEntry?
    /// True for text that a diff can show. Nil when paddock did not look.
    public var text: Bool?
    public var added: Int?
    public var removed: Int?
    public var merge: MergeState?

    public var id: String { path }

    public init(path: String, kind: ChangeKind, state: ChangeState = .open, conflict: String? = nil,
                conflictText: String? = nil, kept: Bool = false, writing: Bool = false, copy: FileEntry? = nil,
                original: FileEntry? = nil, text: Bool? = nil, added: Int? = nil, removed: Int? = nil,
                merge: MergeState? = nil) {
        self.path = path
        self.kind = kind
        self.state = state
        self.conflict = conflict
        self.conflictText = conflictText
        self.kept = kept
        self.writing = writing
        self.copy = copy
        self.original = original
        self.text = text
        self.added = added
        self.removed = removed
        self.merge = merge
    }

    init(_ f: JSONFields) throws {
        guard let path = f.path("path") else { throw CopyContractError("a change has no path") }
        self.init(path: path, kind: ChangeKind(f.string("kind") ?? ""), state: ChangeState(f.string("state") ?? ""),
                  conflict: f.string("conflict"), conflictText: f.string("conflict_text"),
                  kept: f.bool("kept") ?? false, writing: f.bool("writing") ?? false,
                  copy: FileEntry(f.fields["copy"]), original: FileEntry(f.fields["original"]),
                  text: f.bool("text"), added: f.int("added"), removed: f.int("removed"),
                  merge: f.string("merge").flatMap(MergeState.init(rawValue:)))
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The folder of the file from the project folder: `src/cart`, or
    /// empty for a file at the top.
    public var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public var isConflict: Bool { state == .conflict || conflict != nil }
}

/// The pointer of the project in short (`pointer_part`): no size and no
/// disk check.
public struct PointerPart: Equatable, Sendable {
    /// paddock's word of the state. Nil when paddock could not read it.
    public var state: String?
    /// paddock's sentence.
    public var text: String
    /// What to do, in paddock's words. Nil when nothing is to do.
    public var action: String?
    public var ok: Bool
    public var store: String?

    public init(state: String?, text: String, action: String? = nil, ok: Bool, store: String? = nil) {
        self.state = state
        self.text = text
        self.action = action
        self.ok = ok
        self.store = store
    }

    init(_ f: JSONFields?) {
        self.init(state: f?.string("state"), text: f?.string("text") ?? "", action: f?.string("action"),
                  ok: f?.bool("ok") ?? false, store: f?.string("store"))
    }
}

/// `paddock changes RUN --json`.
public struct ChangesDoc: Equatable, Sendable {
    public var run: CopyRun
    public var pointer: PointerPart
    /// The state that an apply must still find: it goes back with the apply.
    public var token: String?
    public var counts: CopyCounts
    public var changes: [FileChange]
    /// The paths that are in your folder already.
    public var applied: [String]
    /// The paths where your folder is newer than the copy's start.
    public var behind: [String]
    /// The paths that paddock does not copy back: devices, sockets.
    public var special: [String]
    /// True when paddock applies the changes by itself at the end of a run.
    public var autoApply: Bool

    public static func decode(_ data: Data) throws -> ChangesDoc {
        let top = try CopyDecode.top(data, CopyAPI.changes)
        guard let run = JSONFields(top.fields["run"]) else { throw CopyContractError("no run") }
        return ChangesDoc(run: try CopyRun(run), pointer: PointerPart(JSONFields(top.fields["pointer"])),
                          token: top.string("token"),
                          counts: JSONFields(top.fields["counts"]).map(CopyCounts.init) ?? CopyCounts(),
                          changes: try top.objects("changes").map(FileChange.init),
                          applied: CopyDecode.paths(top.fields["applied"]),
                          behind: CopyDecode.paths(top.fields["behind"]),
                          special: CopyDecode.paths(top.fields["special"]),
                          autoApply: top.bool("auto_apply") ?? false)
    }

    public func change(_ path: String) -> FileChange? { changes.first { $0.path == path } }
}

// MARK: - The pointer

/// The pointer file of the project folder: it names the store.
public struct PointerFile: Equatable, Sendable {
    public var format: String?
    public var store: String?
    public var created: Date?
}

/// The store of a project: its copies and its backups.
public struct PointerStore: Equatable, Sendable {
    public var id: String
    public var dir: String
    /// The project folder that the store was made for.
    public var original: String?
    public var created: Date?
    public var runs: Int
    public var copies: Int
    public var backups: Int
    public var bytes: Int64
    /// How the size was measured: paddock's word.
    public var sizeKind: String?
}

/// Whether the disk of the store is encrypted.
public enum StoreEncryption: Equatable, Sendable {
    case on(detail: String?)
    case off(detail: String?)
    /// paddock could not tell, or said it in words this launcher does not know.
    case unknown(detail: String?)

    /// paddock writes the answer of its disk check here. It may be a
    /// flag, a word, or an object with a flag and a sentence.
    public init(_ value: JSONValue?) {
        switch value {
        case .bool(let flag)?:
            self = flag ? .on(detail: nil) : .off(detail: nil)
        case .string(let word)?:
            self = StoreEncryption.word(word, detail: nil)
        case .object(let raw)?:
            let f = JSONFields(raw)
            let detail = f.string("text", "detail", "name", "volume", "kind")
            if let flag = f.bool("encrypted", "on", "enabled", "ok") {
                self = flag ? .on(detail: detail) : .off(detail: detail)
            } else if let word = f.string("state", "status", "encryption") {
                self = StoreEncryption.word(word, detail: detail)
            } else {
                self = .unknown(detail: detail)
            }
        default:
            self = .unknown(detail: nil)
        }
    }

    static func word(_ word: String, detail: String?) -> StoreEncryption {
        switch word.lowercased() {
        case "on", "yes", "encrypted", "filevault", "luks", "true": return .on(detail: detail)
        case "off", "no", "none", "plain", "unencrypted", "not_encrypted", "false": return .off(detail: detail)
        default: return .unknown(detail: detail ?? word)
        }
    }
}

/// `paddock pointer status --json`.
public struct PointerDoc: Equatable, Sendable {
    public var project: String
    public var part: PointerPart
    public var pointer: PointerFile?
    public var store: PointerStore?
    public var encryption: StoreEncryption

    public static func decode(_ data: Data) throws -> PointerDoc {
        let top = try CopyDecode.top(data, CopyAPI.pointer)
        var part = PointerPart(top)
        var file: PointerFile?
        if let f = JSONFields(top.fields["pointer"]) {
            file = PointerFile(format: f.string("format"), store: f.string("store"), created: f.seconds("created"))
            part.store = file?.store
        } else {
            part.store = nil
        }
        var store: PointerStore?
        if let f = JSONFields(top.fields["store"]), let dir = f.path("dir") {
            let size = JSONFields(f.fields["size"])
            store = PointerStore(id: f.string("id") ?? "", dir: dir, original: f.path("original"),
                                 created: f.seconds("created"), runs: f.int("runs") ?? 0, copies: f.int("copies") ?? 0,
                                 backups: f.int("backups") ?? 0, bytes: size?.int64("bytes") ?? 0,
                                 sizeKind: size?.string("kind"))
        }
        return PointerDoc(project: top.path("project") ?? "", part: part, pointer: file, store: store,
                          encryption: StoreEncryption(top.fields["encryption"]))
    }
}

// MARK: - Backups

/// One backup of the store (`backup_doc`): what an apply or a restore
/// replaced in your folder.
public struct BackupPoint: Equatable, Sendable, Identifiable {
    public var id: String
    public var short: String
    /// paddock's tag of the reason, such as `apply`.
    public var kind: String
    /// paddock's words for the reason.
    public var words: String
    public var created: Date?
    public var run: String?
    public var harness: String?
    /// The files in the backup.
    public var files: Int
    /// The paths the backup covers, with the ones that had no file.
    public var paths: Int
    public var bytes: Int64
    public var shared: Bool
    public var method: String?
    /// True for a backup of the whole folder.
    public var full: Bool
    /// True once an undo took this apply back.
    public var undone: Bool
    /// True for a backup that an undo made.
    public var byUndo: Bool
    /// True when `paddock undo` can take this apply back.
    public var undoable: Bool

    init(_ f: JSONFields) throws {
        guard let id = f.string("id") else { throw CopyContractError("a backup has no id") }
        self.id = id
        short = f.string("short") ?? id
        kind = f.string("kind") ?? ""
        words = f.string("words") ?? ""
        created = f.seconds("created")
        run = f.string("run")
        harness = f.string("harness")
        files = f.int("files") ?? 0
        paths = f.int("paths") ?? 0
        bytes = f.int64("bytes") ?? 0
        shared = f.bool("shared") ?? false
        method = f.string("method")
        full = f.bool("full") ?? false
        undone = f.isSet("undone")
        byUndo = f.isSet("by_undo")
        undoable = f.bool("undoable") ?? false
    }
}

/// The snapshot of a run that worked in the folder itself. `paddock undo`
/// restores it.
public struct SnapshotPoint: Equatable, Sendable, Identifiable {
    public var id: String
    public var short: String
    public var words: String
    public var created: Date?
    public var harness: String?
    public var files: Int
    public var bytes: Int64
    public var shared: Bool

    init(_ f: JSONFields) throws {
        guard let id = f.string("id") else { throw CopyContractError("a snapshot has no id") }
        self.id = id
        short = f.string("short") ?? id
        words = f.string("words") ?? ""
        created = f.seconds("created")
        harness = f.string("harness")
        files = f.int("files") ?? 0
        bytes = f.int64("bytes") ?? 0
        shared = f.bool("shared") ?? false
    }
}

/// `paddock backups --json`: the backups of the store, newest first, and
/// the snapshots of direct runs.
public struct BackupsDoc: Equatable, Sendable {
    public var project: String
    public var pointer: PointerPart
    public var backups: [BackupPoint]
    public var snapshots: [SnapshotPoint]

    public static func decode(_ data: Data) throws -> BackupsDoc {
        let top = try CopyDecode.top(data, CopyAPI.backups)
        return BackupsDoc(project: top.path("project") ?? "", pointer: PointerPart(JSONFields(top.fields["pointer"])),
                          backups: try top.objects("backups").map(BackupPoint.init),
                          snapshots: try top.objects("snapshots").map(SnapshotPoint.init))
    }

    /// The apply that ⌘Z takes back: the newest backup that can be undone.
    public var undoTarget: BackupPoint? { backups.first { $0.undoable && !$0.undone } }
}

// MARK: - The result of an action

/// The answer of apply, keep, discard, restore or undo (`result`): the
/// body of the action with its `api_version`, and the run and the project
/// when the action has a run. A body that is a list comes as `paths`.
public struct CopyResult: Equatable, Sendable {
    public var api: String
    public var run: String?
    public var project: String?
    public var body: JSONFields

    public static func decode(_ data: Data, _ api: String) throws -> CopyResult {
        let top = try CopyDecode.top(data, api)
        return CopyResult(api: api, run: top.string("run"), project: top.path("project"), body: top)
    }

    /// The paths of the answer, when it lists them.
    public var paths: [String] { CopyDecode.paths(body.fields["paths"]) }

    /// The count under one of `keys`: a number, or the length of a list.
    public func count(_ keys: String...) -> Int? {
        for key in keys {
            switch body.fields[key] {
            case .number(let text)?: if let value = Int(text) { return value }
            case .array(let items)?: return items.count
            default: continue
            }
        }
        return nil
    }

    /// The backup that the action made, when it names one.
    public var backup: String? {
        if let id = body.string("backup", "backup_id") { return id }
        return JSONFields(body.fields["backup"])?.string("id", "short")
    }
}
