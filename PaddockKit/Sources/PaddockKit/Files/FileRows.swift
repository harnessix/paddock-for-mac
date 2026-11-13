import Foundation

// The rows of the Files screen: the mark of a file, the table rows, the
// folder tree with its counts, the filter and the search. Pure rules, so
// they test without AppKit.

/// The mark of a file: a symbol and a word. Color is never the only sign.
public enum FileMark: String, CaseIterable, Equatable, Sendable {
    case new, changed, deleted, conflict, kept
    /// A file of the copy that is the same as yours (All files).
    case same

    public var symbol: String {
        switch self {
        case .new: return "plus.circle.fill"
        case .changed: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        case .kept: return "pause.circle"
        case .same: return "circle"
        }
    }

    public var word: UIText {
        switch self {
        case .new: return UIText("New")
        case .changed: return UIText("Changed")
        case .deleted: return UIText("Deleted")
        case .conflict: return UIText("Conflict")
        case .kept: return UIText("Kept")
        case .same: return UIText("Same")
        }
    }

    /// The word inside a spoken line: `main.rs, changed, …`.
    public var spoken: UIText {
        switch self {
        case .new: return UIText("new")
        case .changed: return UIText("changed")
        case .deleted: return UIText("deleted")
        case .conflict: return UIText("conflict")
        case .kept: return UIText("kept in the copy")
        case .same: return UIText("not changed")
        }
    }

    public var tint: SymbolTint {
        switch self {
        case .new: return .green
        case .changed: return .orange
        case .deleted: return .red
        case .conflict: return .orange
        case .kept, .same: return .secondary
        }
    }

    /// The order of the Change column: what needs you first.
    public var order: Int {
        switch self {
        case .conflict: return 0
        case .changed: return 1
        case .new: return 2
        case .deleted: return 3
        case .kept: return 4
        case .same: return 5
        }
    }

    /// A conflict wins, then Kept, then the kind of the change.
    public static func of(_ change: FileChange) -> FileMark {
        if change.isConflict { return .conflict }
        if change.kept || change.state == .kept { return .kept }
        switch change.kind {
        case .new: return .new
        case .deleted: return .deleted
        case .changed, .other: return .changed
        }
    }
}

/// A file of the copy as the disk lists it, for All files.
public struct ListedFile: Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date?

    public init(path: String, size: Int64, modified: Date? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// One row of the table.
public struct FileRow: Equatable, Sendable, Identifiable {
    public var path: String
    public var mark: FileMark
    public var change: FileChange?
    public var size: Int64?
    public var time: Date?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public var folder: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public init(path: String, mark: FileMark, change: FileChange? = nil, size: Int64? = nil, time: Date? = nil) {
        self.path = path
        self.mark = mark
        self.change = change
        self.size = size
        self.time = time
    }

    /// The row of a change: the size and the time of the copy's file, or
    /// of yours for a deleted file.
    public init(_ change: FileChange) {
        let side = change.copy ?? change.original
        self.init(path: change.path, mark: FileMark.of(change), change: change, size: side?.size, time: side?.mtime)
    }

    // The sort keys of the table columns.
    public var sortName: String { name.lowercased() }
    public var sortMark: Int { mark.order }
    public var sortSize: Int64 { size ?? -1 }
    public var sortTime: Double { time?.timeIntervalSince1970 ?? 0 }

    /// True when the row has something to apply, keep or discard.
    public var isChange: Bool { change != nil }
}

/// What the table shows.
public enum FilesFilter: String, CaseIterable, Equatable, Sendable, Identifiable {
    case changes, all, conflicts

    public var id: String { rawValue }

    public var title: UIText {
        switch self {
        case .changes: return UIText("Changes")
        case .all: return UIText("All files")
        case .conflicts: return UIText("Conflicts")
        }
    }
}

/// One folder of the tree.
public struct FolderNode: Equatable, Sendable, Identifiable {
    /// The path from the project folder; empty for the project itself.
    public var path: String
    public var name: String
    /// The changes in the folder and below it.
    public var changes: Int
    public var conflicts: Int
    public var children: [FolderNode]

    public var id: String { path }
    /// Nil for a folder with no folders in it, as `OutlineGroup` wants.
    public var folders: [FolderNode]? { children.isEmpty ? nil : children }
}

public enum FileRows {
    /// The rows of the table for a filter: the changes, the conflicts, or
    /// every file of the copy with the deleted ones. By path.
    public static func rows(_ doc: ChangesDoc, filter: FilesFilter, listed: [ListedFile] = []) -> [FileRow] {
        let changed = doc.changes.map(FileRow.init)
        switch filter {
        case .changes:
            return changed.sorted(by: inOrder)
        case .conflicts:
            return changed.filter { $0.mark == .conflict }.sorted(by: inOrder)
        case .all:
            var seen = Set(changed.map(\.path))
            var rows = changed
            for file in listed where seen.insert(file.path).inserted {
                rows.append(FileRow(path: file.path, mark: .same, size: file.size, time: file.modified))
            }
            return rows.sorted(by: inOrder)
        }
    }

    static func inOrder(_ a: FileRow, _ b: FileRow) -> Bool {
        a.path.localizedStandardCompare(b.path) == .orderedAscending
    }

    /// The rows in `folder` and below it. The empty folder is all rows.
    public static func inFolder(_ rows: [FileRow], _ folder: String) -> [FileRow] {
        guard !folder.isEmpty else { return rows }
        let prefix = folder + "/"
        return rows.filter { $0.path.hasPrefix(prefix) }
    }

    /// The rows whose path has every word of `text`, in any case.
    public static func search(_ rows: [FileRow], _ text: String) -> [FileRow] {
        let words = text.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let path = row.path.lowercased()
            return words.allSatisfy { path.contains($0) }
        }
    }

    /// The folder tree of `rows`, under a root with the name of the
    /// project. Folders sort by name; each has the count of the changes
    /// in it and below it.
    public static func tree(_ rows: [FileRow], root: String) -> FolderNode {
        final class Box {
            var changes = 0
            var conflicts = 0
            var children: [String: Box] = [:]
        }
        let top = Box()
        for row in rows {
            var boxes = [top]
            var at = top
            for part in row.folder.split(separator: "/").map(String.init) {
                if at.children[part] == nil { at.children[part] = Box() }
                at = at.children[part]!
                boxes.append(at)
            }
            guard row.isChange else { continue }
            for box in boxes {
                box.changes += 1
                if row.mark == .conflict { box.conflicts += 1 }
            }
        }
        func node(_ box: Box, path: String, name: String) -> FolderNode {
            let children = box.children.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { key in node(box.children[key]!, path: path.isEmpty ? key : path + "/" + key, name: key) }
            return FolderNode(path: path, name: name, changes: box.changes, conflicts: box.conflicts, children: children)
        }
        return node(top, path: "", name: root)
    }

    /// The paths of the changes in `folder` and below it.
    public static func changePaths(_ doc: ChangesDoc, in folder: String) -> [String] {
        inFolder(doc.changes.map(FileRow.init), folder).map(\.path)
    }
}

/// The files of a copy on the disk, for All files.
public enum CopyDisk {
    /// The most files that All files lists.
    public static let limit = 5000
    /// Folders that All files does not open: they are large and not yours.
    public static let skipped: Set<String> = [".git", "node_modules", ".build", "target", "DerivedData", ".venv"]

    /// The regular files under `root`, by path, at most `limit`. The
    /// second value is true when the folder has more.
    public static func list(root: String, limit: Int = CopyDisk.limit) -> (files: [ListedFile], more: Bool) {
        let manager = FileManager.default
        var files: [ListedFile] = []
        var more = false
        var stack = [""]
        while let folder = stack.popLast() {
            let full = folder.isEmpty ? root : root + "/" + folder
            guard let names = try? manager.contentsOfDirectory(atPath: full) else { continue }
            for name in names.sorted() {
                let path = folder.isEmpty ? name : folder + "/" + name
                guard let attributes = try? manager.attributesOfItem(atPath: root + "/" + path) else { continue }
                let type = attributes[.type] as? FileAttributeType
                if type == .typeDirectory {
                    if !skipped.contains(name) { stack.append(path) }
                } else if type == .typeRegular || type == .typeSymbolicLink {
                    if files.count >= limit {
                        more = true
                        return (files, more)
                    }
                    files.append(ListedFile(path: path, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                            modified: attributes[.modificationDate] as? Date))
                }
            }
        }
        return (files, more)
    }
}

/// The texts of the Files screens.
public enum FilesCopy {
    public static let emptyTitle = UIText("No changes yet")
    public static let emptyLine = UIText("No changes yet. Your folder stays as it is.")
    public static let noConflicts = UIText("No conflicts. Every change can go to your folder.")
    public static let nothingFound = UIText("No file matches the search.")
    public static let removed = UIText("paddock removed this copy. Nothing is left to apply.")

    /// `812 bytes`, `4 KB`, `1.2 MB`, `3.4 GB`: decimal, as Finder.
    public static func size(_ bytes: Int64) -> UIText {
        let value = Double(max(0, bytes))
        if value < 1000 { return bytes == 1 ? UIText("1 byte") : UIText("%lld bytes", max(0, bytes)) }
        if value < 999_500 { return UIText(key: "%@ KB", args: [String(format: "%.0f", value / 1000)]) }
        if value < 999_950_000 { return UIText(key: "%@ MB", args: [String(format: "%.1f", value / 1_000_000)]) }
        return UIText(key: "%@ GB", args: [String(format: "%.1f", value / 1_000_000_000)])
    }

    /// `3 changes`, `1 change`.
    public static func changes(_ count: Int) -> UIText {
        count == 1 ? UIText("1 change") : UIText("%lld changes", count)
    }

    /// `2 conflicts`, `1 conflict`.
    public static func conflicts(_ count: Int) -> UIText {
        count == 1 ? UIText("1 conflict") : UIText("%lld conflicts", count)
    }

    /// `3 files`, `1 file`.
    public static func files(_ count: Int) -> UIText {
        count == 1 ? UIText("1 file") : UIText("%lld files", count)
    }

    /// The line counts of a change: `12 lines added`, `3 removed`. Empty
    /// when paddock gave none, or for a file that is no text.
    public static func lineParts(added: Int?, removed: Int?) -> [UIText] {
        var parts: [UIText] = []
        if let added, added > 0 {
            parts.append(added == 1 ? UIText("1 line added") : UIText("%lld lines added", added))
        }
        if let removed, removed > 0 {
            if parts.isEmpty {
                parts.append(removed == 1 ? UIText("1 line removed") : UIText("%lld lines removed", removed))
            } else {
                parts.append(removed == 1 ? UIText("1 removed") : UIText("%@ removed", "\(removed)"))
            }
        }
        return parts
    }

    /// What VoiceOver reads for a row, in parts: `main.rs`, `changed`,
    /// `12 lines added`, `3 removed`. The app joins them with commas in
    /// the language of the user.
    public static func spoken(_ row: FileRow) -> [UIText] {
        var parts = [UIText(key: "%@", args: [row.name]), row.mark.spoken]
        if let change = row.change {
            if row.mark == .conflict, let text = change.conflictText {
                parts.append(UIText(key: "%@", args: [text]))
            }
            parts += lineParts(added: change.added, removed: change.removed)
            if change.writing { parts.append(UIText("the agent is writing it")) }
        }
        return parts
    }

    /// The same line in English, for the tests.
    public static func spokenEnglish(_ row: FileRow) -> String {
        spoken(row).map(\.english).joined(separator: ", ")
    }

    /// `+12 −3` under the mark of a row. Nil without counts.
    public static func stat(_ change: FileChange) -> String? {
        guard change.added != nil || change.removed != nil else { return nil }
        var parts: [String] = []
        if let added = change.added, added > 0 { parts.append("+\(added)") }
        if let removed = change.removed, removed > 0 { parts.append("−\(removed)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The line of the entry bar of an agent room: what waits in the copy.
    public static func waiting(_ counts: CopyCounts) -> UIText {
        if counts.conflicts > 0, counts.ready > 0 {
            return UIText("%lld changes wait in the copy, %@ in conflict", counts.waiting, "\(counts.conflicts)")
        }
        if counts.conflicts > 0 {
            return counts.conflicts == 1 ? UIText("1 conflict in the copy")
                : UIText("%lld conflicts in the copy", counts.conflicts)
        }
        if counts.ready > 0 {
            return counts.ready == 1 ? UIText("1 change waits in the copy")
                : UIText("%lld changes wait in the copy", counts.ready)
        }
        if counts.kept > 0 {
            return counts.kept == 1 ? UIText("1 change kept in the copy")
                : UIText("%lld changes kept in the copy", counts.kept)
        }
        return UIText("The copy has no changes")
    }
}
