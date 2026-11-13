import Foundation
import Observation

/// One apply that worked: the Files screen plays its motion once.
public struct ApplyFlight: Equatable, Sendable, Identifiable {
    public var id: Int
    public var run: String
    /// The changes that went to your folder.
    public var changes: Int
}

/// The copies of the agent runs: what each run changed, the backups of a
/// project and its pointer, and the actions on them. paddock is the
/// truth: after every action the store reads the changes again.
@MainActor
@Observable
public final class FilesStore {
    public enum Work: Equatable, Sendable {
        case apply, keep, discard, restore, undo, pointer
    }

    /// The runs with a copy, from `paddock changes --json`.
    public var copies: [CopyRunRow] = []
    public var copiesLoaded = false
    /// False once this paddock answered that it has no `changes` command.
    public var supported = true
    /// The changes of the runs that a Files screen opened, by run id.
    public var docs: [String: ChangesDoc] = [:]
    /// The files of a copy on the disk, for All files, by run id.
    public var listed: [String: [ListedFile]] = [:]
    /// The runs whose copy has more files than All files lists.
    public var listedMore: Set<String> = []
    /// The backups by project folder.
    public var backups: [String: BackupsDoc] = [:]
    /// The pointer by project folder.
    public var pointers: [String: PointerDoc] = [:]
    /// The action that runs now. One at a time.
    public var working: Work?
    /// The last read or action that failed, in the place where it happened.
    public var problem: InlineProblem?
    public var toast: Toast?
    /// The last apply that worked, for the motion.
    public var flight: ApplyFlight?

    @ObservationIgnored let service: () -> PaddockService?
    @ObservationIgnored public let clock: LauncherClock
    /// Lists the files of a copy folder. The tests give their own.
    @ObservationIgnored public var lister: @Sendable (String) async -> (files: [ListedFile], more: Bool) = { root in
        await Task.detached { CopyDisk.list(root: root) }.value
    }
    @ObservationIgnored var flights = 0
    @ObservationIgnored var toastTask: Task<Void, Never>?

    /// A read: the lists can be long, the answer is quick.
    public static let readLimits = RunLimits(seconds: 30, maxBytes: 32 * 1024 * 1024)
    /// An action copies files: it can take minutes on a large project.
    public static let actionLimits = RunLimits(seconds: 600, maxBytes: 32 * 1024 * 1024)

    public init(service: @escaping () -> PaddockService?, clock: LauncherClock = SystemClock()) {
        self.service = service
        self.clock = clock
    }

    // MARK: What the screens ask

    public func row(run id: String?) -> CopyRunRow? {
        guard let id else { return nil }
        return copies.first { $0.run.id == id }
    }

    /// The counts of a run: from its open Files screen, else from the list.
    public func counts(run id: String?) -> CopyCounts? {
        guard let id else { return nil }
        return docs[id]?.counts ?? row(run: id)?.counts
    }

    /// The apply that ⌘Z takes back in `project`.
    public func undoTarget(project: String) -> BackupPoint? {
        backups[project]?.undoTarget
    }

    public func summary(project: String, part: PointerPart) -> PointerSummary {
        PointerSummary(part, doc: pointers[project])
    }

    // MARK: Reads

    /// Reads the runs with a copy.
    public func refreshCopies() async {
        guard let service = service() else { return }
        do {
            let out = try await service.raw(FilesArgs.copies, limits: FilesStore.readLimits)
            guard out.status == 0 else {
                // A paddock that answered before keeps its list: one
                // failed read is not a missing command.
                if !copiesLoaded { supported = false }
                return
            }
            let doc = try CopiesDoc.decode(out.stdout)
            if copies != doc.runs { copies = doc.runs }
            copiesLoaded = true
            supported = true
        } catch {
            if !copiesLoaded { supported = false }
        }
    }

    /// Reads the changes of one run. False when the read failed: the
    /// screen keeps the list it has and shows the problem.
    @discardableResult
    public func load(run id: String, quiet: Bool = false) async -> Bool {
        guard let service = service() else { return false }
        do {
            let out = try await service.raw(FilesArgs.changes(id), limits: FilesStore.readLimits)
            guard out.status == 0 else { throw CommandError.failed(status: out.status, line: CLIPaddockService.lastLine(out.stderr)) }
            let doc = try ChangesDoc.decode(out.stdout)
            if docs[id] != doc { docs[id] = doc }
            return true
        } catch {
            if !quiet { problem = FilesStore.problem(error) }
            return false
        }
    }

    /// Lists the files of the copy for All files.
    public func loadListing(run id: String) async {
        guard let doc = docs[id], !doc.run.copy.isEmpty, doc.run.state != .removed else { return }
        let result = await lister(doc.run.copy)
        if listed[id] != result.files { listed[id] = result.files }
        if result.more { listedMore.insert(id) } else { listedMore.remove(id) }
    }

    public func loadBackups(project: String) async {
        guard let service = service() else { return }
        do {
            let out = try await service.raw(FilesArgs.backups(project: project), limits: FilesStore.readLimits)
            guard out.status == 0 else { throw CommandError.failed(status: out.status, line: CLIPaddockService.lastLine(out.stderr)) }
            let doc = try BackupsDoc.decode(out.stdout)
            if backups[project] != doc { backups[project] = doc }
        } catch {
            // The Backups screen asks itself and shows what failed.
        }
    }

    /// Reads the backups for the Backups screen: a failure shows.
    public func openBackups(project: String) async {
        guard let service = service() else { return }
        problem = nil
        do {
            let out = try await service.raw(FilesArgs.backups(project: project), limits: FilesStore.readLimits)
            guard out.status == 0 else { throw CommandError.failed(status: out.status, line: CLIPaddockService.lastLine(out.stderr)) }
            backups[project] = try BackupsDoc.decode(out.stdout)
        } catch {
            problem = FilesStore.problem(error)
        }
    }

    /// Reads the pointer with the size of the store and the disk check.
    /// The problem of a read that failed, else nil.
    @discardableResult
    public func loadPointer(project: String) async -> InlineProblem? {
        guard let service = service() else { return nil }
        do {
            let out = try await service.raw(FilesArgs.pointer(project: project), limits: FilesStore.readLimits)
            guard out.status == 0 else { throw CommandError.failed(status: out.status, line: CLIPaddockService.lastLine(out.stderr)) }
            pointers[project] = try PointerDoc.decode(out.stdout)
            return nil
        } catch {
            return FilesStore.problem(error)
        }
    }

    // MARK: Actions

    /// Applies the plan to your folder. True when paddock did it.
    @discardableResult
    public func apply(_ plan: ApplyPlan) async -> Bool {
        guard plan.canApply else { return false }
        let name = (plan.project as NSString).lastPathComponent
        var count = 0
        for (index, args) in plan.calls.enumerated() {
            guard let result = await act(.apply, args, api: CopyAPI.apply, run: plan.run) else {
                // A later call failed: what the earlier ones wrote stays, and
                // ⌘Z takes it back.
                if index > 0 { await loadBackups(project: plan.project) }
                return false
            }
            count += result.count("applied", "written", "paths") ?? 0
        }
        if count == 0 { count = plan.count }
        flights += 1
        flight = ApplyFlight(id: flights, run: plan.run, changes: count)
        show(count == 1 ? UIText("Applied 1 change to %@. ⌘Z takes it back.", name)
            : UIText("Applied %lld changes to %@. ⌘Z takes it back.", count, name))
        await loadBackups(project: plan.project)
        return true
    }

    /// Keeps the paths in the copy: Apply All leaves them there.
    @discardableResult
    public func keep(run: String, paths: [String]) async -> Bool {
        guard !paths.isEmpty else { return false }
        guard await act(.keep, FilesArgs.keep(run, paths: paths), api: CopyAPI.keep, run: run) != nil else { return false }
        show(paths.count == 1 ? UIText("Kept 1 change in the copy") : UIText("Kept %lld changes in the copy", paths.count))
        return true
    }

    /// Discards the paths of the copy, or every change (`paths` nil).
    @discardableResult
    public func discard(run: String, paths: [String]?) async -> Bool {
        if let paths, paths.isEmpty { return false }
        let before = docs[run]?.counts.total
        guard let result = await act(.discard, FilesArgs.discard(run, paths: paths), api: CopyAPI.discard, run: run) else {
            return false
        }
        let count = result.count("discarded", "paths") ?? paths?.count ?? before ?? 0
        show(count == 1 ? UIText("Discarded 1 change") : UIText("Discarded %lld changes", count))
        return true
    }

    /// Restores a point of the timeline: all of it, or `paths`.
    @discardableResult
    public func restore(_ point: TimelinePoint, paths: [String]? = nil, project: String, run: String? = nil) async -> Bool {
        let args: [String]
        let api: String
        switch point.source {
        case .backup(let backup):
            args = FilesArgs.restore(backup.id, paths: paths, project: project)
            api = CopyAPI.restore
        case .snapshot(let snapshot):
            args = FilesArgs.undo(snapshot.id)
            api = CopyAPI.undo
        }
        guard await act(.restore, args, api: api, run: run) != nil else { return false }
        let name = (project as NSString).lastPathComponent
        if let paths, paths.count == 1 {
            show(UIText("Restored %@", (paths[0] as NSString).lastPathComponent))
        } else {
            show(UIText("Restored %@", name))
        }
        await loadBackups(project: project)
        return true
    }

    /// ⌘Z: takes the last apply of the project back.
    @discardableResult
    public func undoLastApply(project: String, run: String? = nil) async -> Bool {
        if backups[project] == nil { await loadBackups(project: project) }
        guard let target = undoTarget(project: project) else {
            show(UIText("Nothing to undo"))
            return false
        }
        guard await act(.undo, FilesArgs.undo(target.id), api: CopyAPI.undo, run: run) != nil else { return false }
        show(UIText("Took the last apply back"))
        await loadBackups(project: project)
        return true
    }

    /// Runs the command that paddock named for the state of the pointer.
    @discardableResult
    public func repairPointer(args: [String], project: String) async -> InlineProblem? {
        guard working == nil, let service = service() else { return nil }
        working = .pointer
        defer { working = nil }
        do {
            let out = try await service.raw(args, limits: FilesStore.actionLimits)
            guard out.status == 0 else { throw CommandError.failed(status: out.status, line: CLIPaddockService.lastLine(out.stderr)) }
        } catch {
            return FilesStore.problem(error)
        }
        return await loadPointer(project: project)
    }

    /// One action: runs it, reads its answer, then reads the run and the
    /// list again. Nil when it failed; `problem` then says why.
    func act(_ work: Work, _ args: [String], api: String, run: String?) async -> CopyResult? {
        guard working == nil, let service = service() else { return nil }
        working = work
        problem = nil
        defer { working = nil }
        var result: CopyResult?
        do {
            let out = try await service.raw(args, limits: FilesStore.actionLimits)
            guard out.status == 0 else {
                throw CommandError.failed(status: out.status, line: FilesStore.failureLine(out))
            }
            result = try CopyResult.decode(out.stdout, api)
        } catch {
            problem = FilesStore.problem(error)
        }
        // After a failure too: the list may be the reason (a stale token).
        if let run { await load(run: run, quiet: true) }
        await refreshCopies()
        return result
    }

    /// paddock's line of a failed action: its last stderr line, or the
    /// `error` of a JSON answer.
    static func failureLine(_ out: CommandOutput) -> String {
        let line = CLIPaddockService.lastLine(out.stderr)
        if !line.isEmpty { return line }
        if let fields = try? AgentDecode.object(out.stdout), let text = fields.string("error", "reason", "line", "text") {
            return text
        }
        return ""
    }

    public static let stale = UIText("The copy changed since you looked. Check the list, then apply again.")
    public static let badAnswer = UIText("paddock answered in a form this version does not read. Update paddock for Mac, then try again.")

    /// The problem of a failed read or action.
    public static func problem(_ error: Error) -> InlineProblem {
        switch error {
        case CommandError.failed(_, let line):
            let lower = line.lowercased()
            if lower.contains("token") || lower.contains("changed since") || lower.contains("out of date") {
                return InlineProblem(message: stale, details: line)
            }
            return PlainError.problem(line)
        case CommandError.timedOut:
            return InlineProblem(message: PlainError.noAnswer)
        case CommandError.badJSON(let output):
            return InlineProblem(message: badAnswer, details: output.isEmpty ? nil : output)
        case let error as CopyContractError:
            return InlineProblem(message: badAnswer, details: error.what)
        case is StrictJSON.Invalid:
            return InlineProblem(message: badAnswer)
        default:
            return InlineProblem(message: PlainError.generic)
        }
    }

    // MARK: Toast

    /// Shows a line for a few seconds.
    public func show(_ text: UIText, seconds: Double = 4) {
        let toast = Toast(text)
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self, clock] in
            try? await clock.sleep(seconds: seconds)
            guard !Task.isCancelled else { return }
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }
}
