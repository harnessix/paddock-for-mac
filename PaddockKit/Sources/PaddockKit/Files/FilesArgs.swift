import Foundation

/// What to do with one conflict in an apply.
public enum ConflictChoice: String, CaseIterable, Equatable, Sendable, Identifiable {
    /// The file of the copy replaces yours.
    case copy
    /// Your file stays. The change stays in the copy.
    case original
    /// paddock merges both into your file.
    case merge

    public var id: String { rawValue }

    public var title: UIText {
        switch self {
        case .copy: return UIText("Use the copy")
        case .original: return UIText("Keep mine")
        case .merge: return UIText("Merge both")
        }
    }

    /// What the choice does, under the buttons.
    public var note: UIText {
        switch self {
        case .copy: return UIText("The agent's file replaces yours. paddock backs yours up first.")
        case .original: return UIText("Your file stays as it is. The agent's file stays in the copy.")
        case .merge: return UIText("paddock puts both sets of changes into your file.")
        }
    }

    /// The value of `paddock apply --on-conflict` for the choice.
    public var onConflict: String { rawValue }
}

/// The argument lists of the copy commands of paddock 0.2.4 (`src/cli/copy.rs`
/// and `undo`, `discard` in `src/cli/mod.rs`). One place: the store, the
/// "Terminal" row and the tests agree. Paths follow `--`, so a file named
/// `--json` is a path. An action that would ask a question in a terminal
/// takes `--yes`, which `--json` needs.
public enum FilesArgs {
    /// `paddock changes --json`: every run with a copy.
    public static let copies = ["changes", "--json"]

    /// `paddock changes RUN --json`.
    public static func changes(_ run: String) -> [String] { ["changes", run, "--json"] }

    /// `paddock backups --json` of a project.
    public static func backups(project: String) -> [String] { ["backups", project, "--json"] }

    /// `paddock pointer status --json` of a project.
    public static func pointer(project: String) -> [String] { ["pointer", "status", project, "--json"] }

    /// Apply `paths` of the run to the original, or every ready change
    /// when `paths` is nil. `onConflict` is one value for all conflicts of
    /// the call: `stop`, `original`, `copy`, `both` or `merge`.
    public static func apply(_ run: String, paths: [String]?, token: String?, onConflict: String = "stop") -> [String] {
        var args = ["apply", run, "--on-conflict", onConflict, "--yes", "--json"]
        if let token { args += ["--token", token] }
        return args + tail(paths)
    }

    /// Keep `paths` in the copy: an apply of all leaves them there.
    public static func keep(_ run: String, paths: [String]) -> [String] {
        ["keep", run, "--json"] + tail(paths)
    }

    /// Discard `paths` of the copy, or every change when `paths` is nil.
    public static func discard(_ run: String, paths: [String]?) -> [String] {
        ["discard", run, "--yes", "--json"] + tail(paths)
    }

    /// Restore a backup of `project`: all of it, or `paths`. paddock
    /// takes the current folder without `--project`, and the launcher has
    /// none.
    public static func restore(_ backup: String, paths: [String]?, project: String) -> [String] {
        ["restore", backup, "--project", project, "--yes", "--json"] + tail(paths)
    }

    /// Take an apply back, or bring the folder back to a snapshot.
    public static func undo(_ id: String) -> [String] { ["undo", id, "--yes", "--json"] }

    static func tail(_ paths: [String]?) -> [String] {
        guard let paths, !paths.isEmpty else { return [] }
        return ["--"] + paths
    }

    /// The words of a command line that paddock printed as an action:
    /// `paddock pointer repair '/Users/demo/my shop'`. Nil when the line
    /// is not a paddock command.
    public static func command(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var open = false
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                open = true
            } else if let mark = quote {
                if character == mark { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                open = true
            } else if character == " " || character == "\t" {
                if open || !current.isEmpty { words.append(current) }
                current = ""
                open = false
            } else {
                current.append(character)
            }
        }
        guard quote == nil, !escaped else { return nil }
        if open || !current.isEmpty { words.append(current) }
        guard words.first == "paddock", words.count > 1 else { return nil }
        // A line with shell syntax is no plain command: it only shows.
        if words.contains(where: { ["|", "&&", ";", ">", "<", "||", "&"].contains($0) }) { return nil }
        return Array(words.dropFirst())
    }
}
