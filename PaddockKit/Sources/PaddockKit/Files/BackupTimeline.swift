import Foundation

// The Backups screen: a timeline by day. Each point is a backup of the
// store (what an apply or a restore replaced in your folder) or the
// snapshot of a run that worked in the folder itself.

/// One point of the timeline.
public struct TimelinePoint: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case backup(BackupPoint)
        case snapshot(SnapshotPoint)
    }

    public var source: Source

    public var id: String {
        switch source {
        case .backup(let backup): return "backup:" + backup.id
        case .snapshot(let snapshot): return "snapshot:" + snapshot.id
        }
    }

    public var created: Date? {
        switch source {
        case .backup(let backup): return backup.created
        case .snapshot(let snapshot): return snapshot.created
        }
    }

    /// paddock's words for the point: why it was made.
    public var words: String {
        switch source {
        case .backup(let backup): return backup.words
        case .snapshot(let snapshot): return snapshot.words
        }
    }

    public var harness: String? {
        switch source {
        case .backup(let backup): return backup.harness
        case .snapshot(let snapshot): return snapshot.harness
        }
    }

    public var files: Int {
        switch source {
        case .backup(let backup): return backup.files
        case .snapshot(let snapshot): return snapshot.files
        }
    }

    public var bytes: Int64 {
        switch source {
        case .backup(let backup): return backup.bytes
        case .snapshot(let snapshot): return snapshot.bytes
        }
    }

    public var symbol: String {
        switch source {
        case .snapshot: return "camera.circle"
        case .backup(let backup):
            if backup.undone { return "arrow.uturn.backward.circle" }
            if backup.byUndo { return "arrow.uturn.backward.circle.fill" }
            return backup.full ? "externaldrive.fill.badge.timemachine" : "clock.arrow.circlepath"
        }
    }

    /// A word next to the point when it is not a plain backup.
    public var tag: UIText? {
        switch source {
        case .snapshot: return UIText("Snapshot")
        case .backup(let backup):
            if backup.undone { return UIText("Undone") }
            if backup.byUndo { return UIText("Made by Undo") }
            return backup.full ? UIText("Whole folder") : nil
        }
    }

    /// One file can be restored from a backup. A snapshot restores whole.
    public var restoresOneFile: Bool {
        if case .backup = source { return true }
        return false
    }

    /// The command that restores the whole point of `project`.
    public func restoreArgs(project: String) -> [String] {
        switch source {
        case .backup(let backup): return FilesArgs.restore(backup.id, paths: nil, project: project)
        case .snapshot(let snapshot): return FilesArgs.undo(snapshot.id)
        }
    }

    /// `3 files`, `1.2 MB`.
    public var facts: [UIText] {
        [FilesCopy.files(files), FilesCopy.size(bytes)]
    }
}

/// One day of the timeline.
public struct TimelineDay: Equatable, Sendable, Identifiable {
    /// The start of the day. Nil for the points with no time.
    public var day: Date?
    public var title: UIText
    public var points: [TimelinePoint]

    public var id: String { day.map { "\(Int($0.timeIntervalSince1970))" } ?? "none" }
}

public enum BackupTimeline {
    /// The days of the timeline, newest first, with the newest point
    /// first in each day.
    public static func days(_ doc: BackupsDoc, now: Date, timeZone: TimeZone = .current) -> [TimelineDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let points = (doc.backups.map { TimelinePoint(source: .backup($0)) }
            + doc.snapshots.map { TimelinePoint(source: .snapshot($0)) })
            .enumerated()
            .sorted { a, b in
                let x = a.element.created ?? .distantPast
                let y = b.element.created ?? .distantPast
                return x != y ? x > y : a.offset < b.offset
            }
            .map(\.element)
        var days: [TimelineDay] = []
        for point in points {
            let day = point.created.map { calendar.startOfDay(for: $0) }
            if let last = days.last, last.day == day {
                days[days.count - 1].points.append(point)
            } else {
                days.append(TimelineDay(day: day, title: title(day, now: now, calendar: calendar), points: [point]))
            }
        }
        return days
    }

    /// `Today`, `Yesterday`, `3 Nov`, or `3 Nov 2025` for another year.
    static func title(_ day: Date?, now: Date, calendar: Calendar) -> UIText {
        guard let day else { return UIText("Time not known") }
        let today = calendar.startOfDay(for: now)
        if day == today { return UIText("Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return UIText("Yesterday")
        }
        let text = Format.dayMonth(day, timeZone: calendar.timeZone)
        let year = calendar.component(.year, from: day)
        if year != calendar.component(.year, from: now) {
            return UIText(key: "%@ %@", args: [text, "\(year)"])
        }
        return UIText(key: "%@", args: [text])
    }

    /// The question before a restore of a whole point.
    public static func restoreQuestion(_ point: TimelinePoint, project: String, timeZone: TimeZone = .current) -> UIText {
        let name = (project as NSString).lastPathComponent
        guard let created = point.created else { return UIText("Restore %@ to this point?", name) }
        return UIText("Restore %@ to %@?", name, Format.clock(created, timeZone: timeZone))
    }

    public static let restoreNote = UIText("paddock backs up the files it replaces, so you can take the restore back.")
}

// MARK: - The pointer popover

/// What the pointer chip and its popover show: where the copies of the
/// project live, how large the store is, whether its disk is encrypted,
/// and the one action of the state.
public struct PointerSummary: Equatable, Sendable {
    /// The one action of a state.
    public enum Action: Equatable, Sendable {
        /// All is well: show the store in Finder.
        case reveal(String)
        /// paddock names a command for the state: run it.
        case run(args: [String])
        /// Nothing to run: read the state again.
        case check
    }

    public var ok: Bool
    /// paddock's word of the state, when it gave one.
    public var state: String?
    /// paddock's sentence.
    public var text: String
    /// paddock's advice when it is no command.
    public var advice: String?
    public var action: Action
    public var store: PointerStore?
    public var encryption: StoreEncryption

    public init(_ part: PointerPart, doc: PointerDoc? = nil) {
        let part = doc?.part ?? part
        ok = part.ok
        state = part.state
        text = part.text
        store = doc?.store
        encryption = doc?.encryption ?? .unknown(detail: nil)
        advice = nil
        if let line = part.action, let args = FilesArgs.command(line) {
            action = .run(args: args)
        } else if part.ok, let dir = doc?.store?.dir {
            action = .reveal(dir)
        } else {
            advice = part.action
            action = .check
        }
    }

    /// The words of the chip.
    public var chip: UIText {
        ok ? UIText("Copies safe") : UIText("Copies need you")
    }

    public var symbol: String {
        ok ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    public var actionTitle: UIText {
        switch action {
        case .reveal: return UIText("Show in Finder")
        case .run: return UIText("Repair")
        case .check: return UIText("Check Again")
        }
    }

    /// `1.2 GB`, or nil while paddock has not measured the store.
    public var size: UIText? {
        store.map { FilesCopy.size($0.bytes) }
    }

    public var encryptionWord: UIText {
        switch encryption {
        case .on: return UIText("Encrypted")
        case .off: return UIText("Not encrypted")
        case .unknown: return UIText("Not known")
        }
    }

    public var encryptionSymbol: String {
        switch encryption {
        case .on: return "lock.fill"
        case .off: return "lock.open"
        case .unknown: return "questionmark.circle"
        }
    }

    public var encryptionDetail: String? {
        switch encryption {
        case .on(let detail), .off(let detail), .unknown(let detail): return detail
        }
    }
}
