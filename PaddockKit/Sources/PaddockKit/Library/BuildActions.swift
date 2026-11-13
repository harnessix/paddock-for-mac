import Foundation

/// The base image actions in the form paddock 0.2.x takes them.
extension LauncherStore {
    /// `Pause`: `macvm setup --pause-download --json`. Only the download
    /// pauses; paddock says so when the build is past it.
    public func requestPause() async {
        guard let service else { return }
        buildNote = nil
        buildNoteDetails = nil
        do {
            let out = try await service.raw(LibraryArgs.setupPause)
            let control = try? PaddockJSON.decoder.decode(SetupControlJSON.self, from: out.stdout)
            switch control?.result {
            case "requested"?:
                markPaused(true)
            case nil where out.status == 0:
                markPaused(true)
            case "past_download"?:
                buildNote = LibraryCopy.pastDownload
            case "no_build"?:
                buildNote = PlainError.shown(control?.text ?? "")
                await reloadStatusNow()
            default:
                noteBuildProblem(control?.error ?? control?.text ?? LibraryActions.line(out),
                                 title: UIText("The build did not pause."))
            }
        } catch {
            noteBuildProblem(LauncherStore.line(of: error), title: UIText("The build did not pause."))
        }
    }

    /// A failed Pause, Resume or Update: a plain sentence under the steps,
    /// and paddock's line for its "Details".
    func noteBuildProblem(_ line: String, title: UIText) {
        let problem = PlainError.problem(line)
        buildNote = UIText("%@ %@", title, problem.message)
        buildNoteDetails = problem.details
    }

    /// `Resume` and `Try Again`: `macvm setup --resume --json` to a build
    /// that runs, or a new build child that starts where the last one stopped.
    public func requestResume() async {
        buildNote = nil
        buildNoteDetails = nil
        markPaused(false)
        guard let service else { return }
        if buildRunning {
            if let out = try? await service.raw(LibraryArgs.setupResume), out.status != 0 {
                noteBuildProblem(LibraryActions.line(out), title: UIText("The build did not continue."))
            }
        } else {
            build(resume: true)
        }
    }

    func markPaused(_ paused: Bool) {
        guard case .building(var progress) = golden else { return }
        progress.paused = paused
        if paused { progress.rateSince = nil }
        golden = .building(progress)
    }

    /// `Update to macOS…` / `Rebuild…`: `macvm update --yes`. It has no
    /// `--json`; its `setup` lines come on the event stream.
    public func updateGolden() {
        guard let service, !buildRunning else { return }
        buildRunning = true
        buildNote = nil
        buildNoteDetails = nil
        buildTask = Task { [weak self] in
            var last = ""
            do {
                for try await line in service.lines(LibraryArgs.update) where !line.isEmpty { last = line }
            } catch {
                self?.noteBuildProblem(last.isEmpty ? LauncherStore.line(of: error) : last,
                                       title: UIText("The base image was not updated."))
            }
            self?.buildRunning = false
            await self?.reloadStatusNow()
        }
    }

    /// `Remove` in the remove base image sheet: `macvm remove --yes --json`.
    public func removeBaseImage() async -> Bool {
        guard let service else { return false }
        do {
            let out = try await service.raw(LibraryArgs.macvmRemove)
            struct Removed: Decodable { var freed: Int64?; var freedBytes: Int64?; var error: String?; var ok: Bool? }
            let r = try? PaddockJSON.decoder.decode(Removed.self, from: out.stdout)
            guard out.status == 0, r?.error == nil, r?.ok != false else {
                lastError = .command(title: UIText("The base image was not removed"), line: r?.error ?? LibraryActions.line(out))
                return false
            }
            golden = .none
            show(UIText("Base image removed. %@ freed.", Format.gb(r?.freed ?? r?.freedBytes ?? 0)))
            return true
        } catch {
            lastError = .command(title: UIText("The base image was not removed"), line: LauncherStore.line(of: error))
            return false
        }
    }

    /// Reads `macvm status --json` past the 5 s gate.
    public func reloadStatusNow() async {
        guard let service else { return }
        if let status = try? await service.macvmStatus() { applyStatus(status) }
    }
}
