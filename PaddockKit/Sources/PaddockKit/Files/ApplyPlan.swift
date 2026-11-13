import Foundation

/// What an apply does, before it does it: the files it writes into your
/// folder, the files it deletes there, and the conflicts with the choice
/// of each. The Apply sheet shows it; Apply stays off until every
/// conflict has a choice.
public struct ApplyPlan: Equatable, Sendable {
    public var run: String
    public var project: String
    public var token: String?
    /// True for Apply All: the kept changes stay out. False for the files
    /// that you picked: a kept file that you picked goes too.
    public var all: Bool
    /// New and changed files: paddock writes them into your folder.
    public var writes: [FileChange]
    /// Files that the agent deleted: paddock deletes them in your folder.
    public var deletes: [FileChange]
    public var conflicts: [FileChange]
    /// The kept changes that Apply All leaves in the copy.
    public var left: [FileChange]
    public var choices: [String: ConflictChoice] = [:]

    /// The plan for the whole run (`paths` nil) or for some paths.
    public init(_ doc: ChangesDoc, paths: [String]? = nil) {
        run = doc.run.id
        project = doc.run.project
        token = doc.token
        all = paths == nil
        let wanted = paths.map(Set.init)
        var writes: [FileChange] = []
        var deletes: [FileChange] = []
        var conflicts: [FileChange] = []
        var left: [FileChange] = []
        for change in doc.changes {
            if let wanted, !wanted.contains(change.path) { continue }
            let mark = FileMark.of(change)
            if mark == .conflict {
                conflicts.append(change)
            } else if mark == .kept, wanted == nil {
                left.append(change)
            } else if change.kind == .deleted {
                deletes.append(change)
            } else {
                writes.append(change)
            }
        }
        self.writes = writes
        self.deletes = deletes
        self.conflicts = conflicts
        self.left = left
    }

    /// The files the apply touches in your folder, with the conflicts
    /// that you did not leave as they are.
    public var count: Int {
        writes.count + deletes.count + conflicts.filter { choices[$0.path] != nil && choices[$0.path] != .original }.count
    }

    public var isEmpty: Bool { writes.isEmpty && deletes.isEmpty && conflicts.isEmpty }

    public var open: [FileChange] { conflicts.filter { choices[$0.path] == nil } }

    /// Apply is on when the plan has something and every conflict has a choice.
    public var canApply: Bool { !isEmpty && open.isEmpty }

    /// The files that the agent still writes: the sheet warns about them.
    public var writing: [FileChange] { (writes + deletes + conflicts).filter(\.writing) }

    /// The choices a conflict offers. A merge needs text on both sides:
    /// no merge of a binary file, a symlink or a deleted file.
    public static func choices(for change: FileChange) -> [ConflictChoice] {
        var all: [ConflictChoice] = [.copy, .original]
        let hasBoth = change.copy != nil && change.original != nil
        let isLink = change.copy?.link != nil || change.original?.link != nil
        if hasBoth, !isLink, change.text != false { all.append(.merge) }
        return all
    }

    /// What a merge of the conflict gives, when paddock tried it.
    public static func mergeNote(_ change: FileChange) -> UIText? {
        switch change.merge {
        case .clean?: return UIText("Both sets of changes fit together.")
        case .conflicts?: return UIText("Some lines changed on both sides: paddock marks them in the file.")
        case nil: return nil
        }
    }

    /// Chooses for one conflict. A choice the conflict does not offer is ignored.
    public mutating func choose(_ choice: ConflictChoice, for path: String) {
        guard let change = conflicts.first(where: { $0.path == path }),
              ApplyPlan.choices(for: change).contains(choice) else { return }
        choices[path] = choice
    }

    /// The same choice for every conflict that offers it.
    public mutating func chooseAll(_ choice: ConflictChoice) {
        for change in conflicts where ApplyPlan.choices(for: change).contains(choice) {
            choices[change.path] = choice
        }
    }

    /// The paths of the apply: the writes, the deletes and the conflicts.
    /// Apply All with no conflict names no path: paddock applies all that
    /// is ready.
    public var paths: [String]? {
        if all, conflicts.isEmpty { return nil }
        return (writes + deletes + conflicts).map(\.path)
    }

    /// The calls of the apply, in order. paddock takes one choice for all
    /// conflicts of a call, so each choice is a call of its own. The first
    /// call carries the token: the calls after it see the list that the
    /// first one changed. "Keep mine" needs no call: your file stays.
    public var calls: [[String]] {
        var calls: [[String]] = []
        let ready = (writes + deletes).map(\.path)
        if paths == nil {
            calls.append(FilesArgs.apply(run, paths: nil, token: token))
        } else if !ready.isEmpty {
            calls.append(FilesArgs.apply(run, paths: ready, token: token))
        }
        for choice in [ConflictChoice.copy, .merge] {
            let picked = conflicts.map(\.path).filter { choices[$0] == choice }
            guard !picked.isEmpty else { continue }
            calls.append(FilesArgs.apply(run, paths: picked, token: calls.isEmpty ? token : nil,
                                         onConflict: choice.onConflict))
        }
        return calls
    }

    /// The title of the sheet: `Apply 3 changes to shop?`.
    public var title: UIText {
        let name = (project as NSString).lastPathComponent
        let total = writes.count + deletes.count + conflicts.count
        return total == 1 ? UIText("Apply 1 change to %@?", name) : UIText("Apply %lld changes to %@?", total, name)
    }
}

/// The motion of an apply: the changed parts go from the model on the
/// desk to the house. With Reduce Motion nothing moves and a check mark
/// shows in its place.
public enum ApplyMotion {
    /// The length of the move, in seconds.
    public static let seconds: Double = 0.7
    /// How long the check mark stays, in seconds.
    public static let checkSeconds: Double = 1.6
    /// The most parts that fly: more changes are still that many parts.
    public static let maxParts = 6

    public enum Style: Equatable, Sendable {
        /// Parts fly from the desk to the house.
        case fly(parts: Int)
        /// A check mark on the house.
        case check
    }

    public static func style(changes: Int, reduceMotion: Bool, still: Bool = false) -> Style {
        if reduceMotion || still || changes <= 0 { return .check }
        return .fly(parts: min(maxParts, changes))
    }

    /// The model on the desk glows while changes wait for you.
    public static func glows(_ counts: CopyCounts?) -> Bool {
        (counts?.waiting ?? 0) > 0
    }

    /// The start of part `index` of `parts`, as a share of the move: the
    /// parts leave one after the other in the first third.
    public static func delay(part index: Int, of parts: Int) -> Double {
        guard parts > 1 else { return 0 }
        return seconds / 3 * Double(index) / Double(parts - 1)
    }
}
