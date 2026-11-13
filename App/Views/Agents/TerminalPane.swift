import AppKit
import PaddockKit
import SwiftTerm
import SwiftUI

/// The terminal views of the agent panes. A view lives here, not in
/// SwiftUI: a pane keeps its process and its screen while another room or
/// another section shows, and SwiftUI only borrows the view.
@MainActor
final class TerminalPanes {
    static let shared = TerminalPanes()

    private(set) var terminals: [String: PaneTerminal] = [:]

    /// The process of a new pane, for `AgentStore.makeProcess`.
    func process(for pane: AgentPane) -> AgentProcess {
        let terminal = PaneTerminal(paneID: pane.id)
        terminals[pane.id] = terminal
        return terminal
    }

    func terminal(_ paneID: String) -> PaneTerminal? { terminals[paneID] }

    /// Forgets the view of a closed pane.
    func remove(_ paneID: String) {
        terminals[paneID] = nil
    }
}

/// One pane: a SwiftTerm view with a local process in a pseudo terminal.
/// It runs `paddock run AGENT …` or `paddock view ID --write` through the
/// user's login shell (`AgentCommand`).
@MainActor
final class PaneTerminal: NSObject, AgentProcess, LocalProcessTerminalViewDelegate {
    let paneID: String
    let view: LocalProcessTerminalView
    var onExit: ((Int32?) -> Void)?
    private(set) var running = false
    private(set) var exitCode: Int32?
    /// Terminations so far: the first sends SIGTERM, a later one SIGKILL.
    private var stops = 0
    /// The child of the pane, from `startProcess`.
    private var childPid: pid_t = 0
    /// Our own watch on the exit of the child. SwiftTerm 1.11.2 has one too,
    /// but it cancels that watch when the pty reads EOF, and the EOF can come
    /// before the exit event: then `processTerminated` never comes.
    private var exitWatch: DispatchSourceProcess?

    init(paneID: String) {
        self.paneID = paneID
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.setAccessibilityIdentifier("agent-terminal-" + paneID)
        view.setAccessibilityLabel(String(localized: "Agent terminal"))
    }

    /// Starts the command. SwiftTerm feeds the output to the view on the
    /// main queue (`DispatchQueue.main.sync` from its read queue), so the
    /// main queue must stay free: no blocking wait on the main thread.
    func start(_ command: AgentCommand) {
        running = true
        exitCode = nil
        stops = 0
        view.startProcess(executable: command.executable, args: command.args, environment: command.environment,
                          execName: nil, currentDirectory: command.directory)
        let pid = view.process.shellPid
        guard view.process.running, pid > 0 else {
            // forkpty failed: SwiftTerm reports nothing.
            ended(nil)
            return
        }
        childPid = pid
        watchExit(of: pid)
    }

    private func watchExit(of pid: pid_t) {
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reap(pid) }
        }
        exitWatch = watch
        watch.activate()
        // A child that ended before the watch began gives no event.
        reap(pid)
    }

    /// Collects the status of an ended child. When SwiftTerm took it first,
    /// its `processTerminated` has already ended the pane.
    private func reap(_ pid: pid_t) {
        guard running, pid == childPid else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            ended(PaneTerminal.exitStatus(status))
        } else if result < 0, errno == ECHILD {
            ended(nil)
        }
    }

    /// The child ended: once, with the first status that comes.
    private func ended(_ code: Int32?) {
        guard running else { return }
        running = false
        exitCode = code
        exitWatch?.cancel()
        exitWatch = nil
        onExit?(code)
    }

    /// Ends the process and keeps its screen: SIGTERM first, so paddock
    /// stops the sandbox; SIGKILL when it is asked again. SwiftTerm's own
    /// `terminate` would close the screen and lose the exit status.
    func terminate() {
        guard running, childPid > 0 else { return }
        stops += 1
        kill(childPid, stops == 1 ? SIGTERM : SIGKILL)
    }

    /// The pid of the process, or 0.
    var pid: pid_t { running ? childPid : 0 }

    /// The visible screen as text, one line per row, without the blanks at
    /// the end of the lines: for the checks.
    var screenText: String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// SwiftTerm 1.11.2 calls this on the main queue, from its exit watch,
    /// with the raw `waitpid` status.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let code = exitCode.map(PaneTerminal.exitStatus)
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.ended(code) }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.ended(code) }
            }
        }
    }

    /// The exit code of a `waitpid` status: the code of a normal exit, or
    /// 128 + the signal, as a shell reports it.
    nonisolated static func exitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }
}

/// The SwiftUI side of a pane: it shows the long-lived terminal view of
/// the pane, and gives it back when it goes.
struct TerminalPaneView: NSViewRepresentable {
    let terminal: PaneTerminal

    func makeNSView(context: Context) -> PaneHost {
        let host = PaneHost()
        host.show(terminal.view)
        return host
    }

    func updateNSView(_ host: PaneHost, context: Context) {
        host.show(terminal.view)
    }

    static func dismantleNSView(_ host: PaneHost, coordinator: ()) {
        host.release()
    }
}

/// Holds the terminal view while SwiftUI shows the pane. The terminal is
/// taken from an old host, if any: one view has one superview.
final class PaneHost: NSView {
    private weak var shown: NSView?

    func show(_ view: NSView) {
        guard shown !== view || view.superview !== self else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        shown = view
        // The keys go to the agent once the pane shows.
        DispatchQueue.main.async { [weak view] in
            MainActor.assumeIsolated {
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    func release() {
        if let shown, shown.superview === self { shown.removeFromSuperview() }
        shown = nil
    }
}

/// "Open in Terminal": hands the run to Terminal.app, or the app that
/// opens `.command` files, through `paddock view ID --write`.
@MainActor
enum TerminalHandoffAction {
    /// Writes the `.command` file and opens it. Returns false when it
    /// could not.
    @discardableResult
    static func open(runID: String) -> Bool {
        guard let paddock = AppContainer.paddockPath else { return false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paddock-views", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(TerminalHandoff.fileName(id: runID))
        do {
            try TerminalHandoff.script(paddock: paddock, id: runID).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        #if DEBUG
        // UI tests check the file, not a Terminal window.
        if AppContainer.isUITest { return true }
        #endif
        return NSWorkspace.shared.open(url)
    }
}
