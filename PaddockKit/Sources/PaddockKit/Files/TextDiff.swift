import Foundation

// The text preview of a change: your file on the left, the copy's on the
// right, by line. The diff is Myers' shortest edit script on the lines,
// after the common start and end are cut off.

/// What the preview can show of a file.
public enum TextSniff {
    /// paddock shows no diff above this size (`TEXT_MAX` of the core).
    public static let maxBytes = 1 << 20

    /// True for UTF-8 text with no NUL byte, at most `maxBytes` long.
    public static func isText(_ data: Data) -> Bool {
        guard data.count <= maxBytes else { return false }
        if data.contains(0) { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// The lines of a text. A final newline ends the last line: it makes
    /// no empty line. `\r\n` ends a line too.
    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // "\r\n" is one character in Swift: make it "\n" before the split.
        let unix = text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        var lines = unix.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if unix.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}

/// One line of a unified diff.
public struct DiffLine: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case same, removed, added
    }

    public var id: Int
    public var kind: Kind
    /// The line number in your file. Nil for an added line.
    public var left: Int?
    /// The line number in the copy's file. Nil for a removed line.
    public var right: Int?
    public var text: String
}

/// One row of the side by side view.
public struct DiffRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case same
        /// A line of yours next to the line of the copy that replaces it.
        case changed
        case removed
        case added
        /// Lines that are the same on both sides and are folded away.
        case fold(Int)
    }

    public struct Side: Equatable, Sendable {
        public var number: Int
        public var text: String

        public init(number: Int, text: String) {
            self.number = number
            self.text = text
        }
    }

    public var id: Int
    public var kind: Kind
    public var left: Side?
    public var right: Side?
}

public struct TextDiff: Equatable, Sendable {
    /// Every line of both files, in the order of a unified diff.
    public var lines: [DiffLine]
    public var added: Int
    public var removed: Int
    /// True when the files were too far apart for a line diff: the whole
    /// of yours shows as removed, the whole of the copy's as added.
    public var coarse: Bool

    /// The most edits the line diff follows.
    public static let maxEdits = 1500

    public init(old: String, new: String) {
        self.init(old: TextSniff.lines(old), new: TextSniff.lines(new))
    }

    public init(old: [String], new: [String]) {
        // The common start and end need no search.
        var start = 0
        while start < old.count, start < new.count, old[start] == new[start] { start += 1 }
        var endOld = old.count
        var endNew = new.count
        while endOld > start, endNew > start, old[endOld - 1] == new[endNew - 1] {
            endOld -= 1
            endNew -= 1
        }
        let a = Array(old[start..<endOld])
        let b = Array(new[start..<endNew])
        var edits = TextDiff.myers(a, b)
        var coarse = false
        if edits == nil {
            coarse = true
            edits = Array(repeating: .removed, count: a.count) + Array(repeating: .added, count: b.count)
        }

        var lines: [DiffLine] = []
        lines.reserveCapacity(old.count + b.count)
        var left = 0
        var right = 0
        func push(_ kind: DiffLine.Kind) {
            switch kind {
            case .same:
                lines.append(DiffLine(id: lines.count, kind: .same, left: left + 1, right: right + 1, text: old[left]))
                left += 1
                right += 1
            case .removed:
                lines.append(DiffLine(id: lines.count, kind: .removed, left: left + 1, right: nil, text: old[left]))
                left += 1
            case .added:
                lines.append(DiffLine(id: lines.count, kind: .added, left: nil, right: right + 1, text: new[right]))
                right += 1
            }
        }
        for _ in 0..<start { push(.same) }
        for edit in edits ?? [] { push(edit) }
        while left < old.count { push(.same) }

        self.lines = lines
        self.coarse = coarse
        added = lines.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) }
        removed = lines.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) }
    }

    public var isEmpty: Bool { added == 0 && removed == 0 }

    /// The shortest edit script from `a` to `b`, with each removed block
    /// before the added block that replaces it. Nil past `maxEdits`.
    static func myers(_ a: [String], _ b: [String]) -> [DiffLine.Kind]? {
        let n = a.count
        let m = b.count
        if n == 0 { return Array(repeating: .added, count: m) }
        if m == 0 { return Array(repeating: .removed, count: n) }
        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int32](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int32]] = []
        var found = -1
        search: for d in 0...limit {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = Int(v[offset + k + 1])
                } else {
                    x = Int(v[offset + k - 1]) + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = Int32(x)
                if x >= n, y >= m {
                    found = d
                    break search
                }
                k += 2
            }
        }
        guard found >= 0 else { return nil }

        // Walk back from the end through the kept rows of `v`.
        var edits: [DiffLine.Kind] = []
        var x = n
        var y = m
        var d = found
        while d > 0 {
            let row = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && row[offset + k - 1] < row[offset + k + 1]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = Int(row[offset + previousK])
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                edits.append(.same)
                x -= 1
                y -= 1
            }
            if x == previousX {
                edits.append(.added)
                y -= 1
            } else {
                edits.append(.removed)
                x -= 1
            }
            d -= 1
        }
        while x > 0, y > 0 {
            edits.append(.same)
            x -= 1
            y -= 1
        }
        edits.reverse()
        return TextDiff.removedFirst(edits)
    }

    /// Within a block of edits between two same lines, the removed lines
    /// come first, as a unified diff prints them.
    static func removedFirst(_ edits: [DiffLine.Kind]) -> [DiffLine.Kind] {
        var out: [DiffLine.Kind] = []
        out.reserveCapacity(edits.count)
        var removed = 0
        var added = 0
        func flush() {
            out += Array(repeating: DiffLine.Kind.removed, count: removed)
            out += Array(repeating: DiffLine.Kind.added, count: added)
            removed = 0
            added = 0
        }
        for edit in edits {
            switch edit {
            case .same:
                flush()
                out.append(.same)
            case .removed: removed += 1
            case .added: added += 1
            }
        }
        flush()
        return out
    }

    /// The rows of the side by side view: in a block of edits, the first
    /// removed line stands next to the first added line, and so on. With
    /// `context`, a run of same lines longer than twice the context is
    /// folded to one row.
    public func rows(context: Int? = nil) -> [DiffRow] {
        var rows: [DiffRow] = []
        var index = 0
        func add(_ kind: DiffRow.Kind, _ left: DiffLine?, _ right: DiffLine?) {
            rows.append(DiffRow(id: rows.count, kind: kind,
                                left: left.flatMap { line in line.left.map { DiffRow.Side(number: $0, text: line.text) } },
                                right: right.flatMap { line in line.right.map { DiffRow.Side(number: $0, text: line.text) } }))
        }
        while index < lines.count {
            let line = lines[index]
            if line.kind == .same {
                add(.same, line, line)
                index += 1
                continue
            }
            var removed: [DiffLine] = []
            var added: [DiffLine] = []
            while index < lines.count, lines[index].kind != .same {
                if lines[index].kind == .removed { removed.append(lines[index]) } else { added.append(lines[index]) }
                index += 1
            }
            for i in 0..<max(removed.count, added.count) {
                let l = i < removed.count ? removed[i] : nil
                let r = i < added.count ? added[i] : nil
                add(l != nil && r != nil ? .changed : (l != nil ? .removed : .added), l, r)
            }
        }
        guard let context else { return rows }
        return TextDiff.fold(rows, context: context) { $0.kind == .same } fold: { id, count in
            DiffRow(id: id, kind: .fold(count), left: nil, right: nil)
        } renumber: { row, id in
            var row = row
            row.id = id
            return row
        }
    }

    /// The lines of the unified view, with long runs of same lines
    /// folded. A fold is a line of kind `same` with no numbers; its text
    /// is the count.
    public func unified(context: Int? = nil) -> [DiffLine] {
        guard let context else { return lines }
        return TextDiff.fold(lines, context: context) { $0.kind == .same } fold: { id, count in
            DiffLine(id: id, kind: .same, left: nil, right: nil, text: String(count))
        } renumber: { line, id in
            var line = line
            line.id = id
            return line
        }
    }

    /// True for a fold line of `unified(context:)`.
    public static func isFold(_ line: DiffLine) -> Bool {
        line.kind == .same && line.left == nil && line.right == nil
    }

    /// Replaces each run of same items longer than `2 * context + 1` by
    /// its first and last `context` items around one fold. A run at the
    /// start keeps only its end, a run at the end only its start.
    static func fold<T>(_ items: [T], context: Int, isSame: (T) -> Bool, fold: (Int, Int) -> T,
                        renumber: (T, Int) -> T) -> [T] {
        var out: [T] = []
        var index = 0
        func push(_ item: T) { out.append(renumber(item, out.count)) }
        while index < items.count {
            guard isSame(items[index]) else {
                push(items[index])
                index += 1
                continue
            }
            var end = index
            while end < items.count, isSame(items[end]) { end += 1 }
            let count = end - index
            let head = index == 0 ? 0 : context
            let tail = end == items.count ? 0 : context
            if count > head + tail + 1 {
                for i in index..<(index + head) { push(items[i]) }
                out.append(fold(out.count, count - head - tail))
                for i in (end - tail)..<end { push(items[i]) }
            } else {
                for i in index..<end { push(items[i]) }
            }
            index = end
        }
        return out
    }
}
