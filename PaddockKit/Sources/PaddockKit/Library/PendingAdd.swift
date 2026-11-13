import Foundation

/// An app that waits for the base image. Add App with no base image keeps
/// the app here and goes on to the base image step. The window shows the
/// app's room with the build. When the base image is ready, the add runs
/// by itself and the window selects the new app.
public struct PendingAdd: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The base image is not ready yet.
        case waiting
        /// The base image is ready: paddock checks and adds the app.
        case adding
        /// The add did not work: paddock's line. Try Again runs it again.
        case failed(String)
    }

    /// The `.app` bundle on this Mac.
    public var path: String
    public var phase: Phase

    public init(path: String, phase: Phase = .waiting) {
        self.path = path
        self.phase = phase
    }

    /// `Notebook` for `/Applications/Notebook.app`.
    public var title: String { AddReview.slugBase(path) }

    /// The line under the name of the app, in its room and in the sidebar.
    public func status(golden: GoldenState) -> UIText {
        switch phase {
        case .adding: return UIText("Adding…")
        case .failed: return UIText("Not added")
        case .waiting:
            switch golden {
            case .building: return UIText("Waits for the base image")
            case .failed: return UIText("Waits for the base image · the build stopped")
            default: return UIText("Needs the base image")
            }
        }
    }

    /// The sentence of the app's room: what happens next.
    public func next(golden: GoldenState) -> UIText {
        switch phase {
        case .adding: return UIText("The base image is ready. paddock adds %@ now.", title)
        case .failed: return UIText("%@ was not added", title)
        case .waiting:
            switch golden {
            case .building: return UIText("%@ is added when the base image is ready. You do not need to wait here.", title)
            case .failed: return UIText("%@ is added when the base image is ready. The build stopped: see below.", title)
            default: return UIText("%@ needs the base image. Build it once; %@ is added when it is ready.", title, title)
            }
        }
    }

    /// The problem of a failed add, for the inline error.
    public var problem: InlineProblem? {
        if case .failed(let line) = phase { return PlainError.problem(line) }
        return nil
    }

    /// The pose of the character in the app's room: it works while the
    /// image builds or the add runs, and it is blocked after a failure.
    public func pose(golden: GoldenState) -> CharacterPose {
        switch phase {
        case .failed: return .blocked
        case .adding: return .work
        case .waiting:
            switch golden {
            case .building(let progress): return progress.paused ? .idle : .work
            case .failed: return .blocked
            default: return .idle
            }
        }
    }
}

extension LauncherStore {
    /// Keeps `path` for after the build. One app waits at a time: a new
    /// one takes the place of the old one.
    public func keepForBaseImage(_ path: String) {
        pendingAdd = PendingAdd(path: path)
        startPendingAddIfReady()
    }

    /// "Do not add": the app does not wait any more. A build goes on.
    public func dropPendingAdd() {
        pendingAdd = nil
    }

    /// Try Again after a failed add.
    public func retryPendingAdd() {
        guard let pending = pendingAdd, case .failed = pending.phase else { return }
        pendingAdd = PendingAdd(path: pending.path)
        startPendingAddIfReady()
    }

    /// Starts the add of the app that waits, once the base image is ready.
    /// Called after every read of the base image state.
    func startPendingAddIfReady() {
        guard golden.isReady, let pending = pendingAdd, pending.phase == .waiting else { return }
        pendingAdd = PendingAdd(path: pending.path, phase: .adding)
        Task { await self.finishPendingAdd(path: pending.path) }
    }

    /// paddock's review, then the add with paddock's name and memory. The
    /// new app is selected. A refusal stays with the app, as an inline
    /// error with Try Again.
    func finishPendingAdd(path: String) async {
        let review = await review(path: path)
        guard pendingAdd?.path == path else { return }
        if let existing = review.existing {
            // The app is in paddock already: show it.
            pendingAdd = nil
            selection = .app(existing)
            openRoom = .app(existing)
            detailTab = .overview
            return
        }
        guard review.canAdd else {
            failPendingAdd(path: path, line: review.firstFailure?.detail.english ?? review.failure ?? "")
            return
        }
        switch await add(path: path, name: review.name, memoryGB: review.defaultMemory) {
        case .added(let key):
            if pendingAdd?.path == path { pendingAdd = nil }
            post(Notice(id: "app-added-" + key, kind: .appAdded, title: UIText("%@ is ready", title(of: key)),
                        body: UIText("The base image is built and the app has its room. Start it when you want."),
                        target: .app(key)))
        case .refused(let line):
            failPendingAdd(path: path, line: line)
        }
    }

    func failPendingAdd(path: String, line: String) {
        guard let pending = pendingAdd, pending.path == path else { return }
        pendingAdd = PendingAdd(path: path, phase: .failed(line))
        post(Notice(id: "add-failed-\(path)-\(postedNotices.count)", kind: .addFailed,
                    title: UIText("%@ was not added", pending.title), body: PlainError.problem(line).message,
                    target: .baseImage))
    }
}
