import AppKit
import Observation
import PaddockKit
import SwiftUI

/// The keys of the launcher's own settings.
enum SettingsKey {
    static let showInMenuBar = "showInMenuBar"
    static let keepRunning = "keepRunningOnQuit"
    static let notifyAfter = "notifyAfterSeconds"
    static let defaultNetwork = "defaultNetwork"
    static let panelPosition = "panelPosition"
    static let showCommands = "showCommands"
    /// `list` or `rooms`: the last choice of the library toolbar.
    static let libraryLayout = "libraryLayout"
    /// The last network level of the New Agent sheet.
    static let agentNetwork = "agentNetwork"
    /// The choice of "How the agent works" of an older launcher: `auto`
    /// or `manual`, one for all agents. Each agent now has its own key
    /// (`AgentModeMemory.key`); this one is only read.
    static let agentMode = AgentModeMemory.legacyKey
    /// True once the welcome window ended with Start or "Skip for now".
    /// It is no setting: `reset` leaves it.
    static let welcomeDone = "welcomeDone"
    /// The shell that paddock for Mac asks for the PATH: a full path. No
    /// value: the login shell.
    static let shellPath = "shellPath"
}

enum LauncherDefaults {
    /// Debug builds can use a separate defaults suite, so each UI test
    /// starts from clean settings.
    static let store: UserDefaults = {
        #if DEBUG
        if let suite = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_DEFAULTS"],
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        #endif
        return .standard
    }()

    static var keepRunning: Bool {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_KEEP_RUNNING"] { return value != "0" }
        #endif
        return store.object(forKey: SettingsKey.keepRunning) as? Bool ?? true
    }

    /// Seconds before a waiting question notifies; nil for never.
    static var notifyAfter: TimeInterval? {
        let value = store.object(forKey: SettingsKey.notifyAfter) as? Int ?? 30
        return value > 0 ? TimeInterval(value) : nil
    }

    /// True when the welcome window already ended on this Mac. A debug
    /// build takes PADDOCK_LAUNCHER_WELCOMED (`1` or `0`) first, so a UI
    /// test can start past the welcome.
    static var welcomeDone: Bool {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_WELCOMED"] { return value != "0" }
        #endif
        return store.bool(forKey: SettingsKey.welcomeDone)
    }

    static func setWelcomeDone() {
        store.set(true, forKey: SettingsKey.welcomeDone)
    }

    /// The shell of Settings, or nil for the login shell.
    static var shellPath: String? {
        let value = store.string(forKey: SettingsKey.shellPath)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static var defaultNetwork: NetworkMode {
        NetworkMode(rawValue: store.string(forKey: SettingsKey.defaultNetwork) ?? "ask") ?? .ask
    }

    /// `Reset paddock for Mac settings`.
    static func reset() {
        for key in [SettingsKey.showInMenuBar, SettingsKey.keepRunning, SettingsKey.notifyAfter,
                    SettingsKey.defaultNetwork, SettingsKey.panelPosition, SettingsKey.showCommands,
                    SettingsKey.libraryLayout, SettingsKey.agentNetwork, SettingsKey.agentMode,
                    SettingsKey.shellPath] {
            store.removeObject(forKey: key)
        }
        // The mode of each agent: after a reset every agent asks first again.
        for key in store.dictionaryRepresentation().keys where AgentModeMemory.isAgentKey(key) {
            store.removeObject(forKey: key)
        }
    }
}

/// The sheets of the main window. Commands and the menu bar extra open them
/// through the router.
enum MainSheet: Identifiable, Equatable {
    case addApp(path: String?)
    /// The New Agent sheet, with a folder from a drop.
    case newAgent(folder: String?)
    /// Stop an agent run: by room key.
    case confirmStopAgent(String)
    case removeApp(String)
    case confirmStop(String)
    case clearState(String)
    case uninstall
    case removeGolden
    case rebuild
    case cancelBuild

    var id: String {
        switch self {
        case .addApp(let path): return "add:" + (path ?? "")
        case .newAgent(let folder): return "agent:" + (folder ?? "")
        case .confirmStopAgent(let key): return "stopAgent:" + key
        case .removeApp(let name): return "remove:" + name
        case .confirmStop(let name): return "stop:" + name
        case .clearState(let name): return "clear:" + name
        case .uninstall: return "uninstall"
        case .removeGolden: return "removeGolden"
        case .rebuild: return "rebuild"
        case .cancelBuild: return "cancelBuild"
        }
    }
}

@MainActor
@Observable
final class UIRouter {
    var sheet: MainSheet?
    /// The step of the welcome window: `WelcomeStep.rawValue`.
    var welcomeStep = WelcomeStep.welcome.rawValue
    /// Set when Add App led to the base image step, or when that step
    /// started the build: the page then offers Add App after the build.
    var addAfterBuild = false
    /// The app that waits for the base image, from a drop.
    var pendingApp: String?
    /// The card of the Questions list that a notice points to: the id of
    /// a question or of an agent request. The list scrolls to it and
    /// marks it; the list clears it when the card goes.
    var focusCard: String?

    /// Add App…: the review sheet. While no base image is there, the base
    /// image step of the Apps section comes first; it keeps `path` for
    /// after the build.
    ///
    /// The store keeps the app too (`pendingAdd`): the step shows its
    /// room, and when the build ends the add goes on by itself and the
    /// window selects the new app.
    func addApp(path: String?, store: LauncherStore) {
        guard store.addNeedsBaseImage else {
            // The base image is there: nothing waits for it any more.
            addAfterBuild = false
            pendingApp = nil
            sheet = .addApp(path: path)
            return
        }
        // Add App with no path keeps an app that a drop left waiting.
        pendingApp = path ?? pendingApp
        addAfterBuild = true
        if let path { store.keepForBaseImage(path) }
        store.selection = .baseImage
    }

    /// The review sheet found that the base image is missing: the app
    /// waits, and the window goes straight on to the base image step.
    func waitForBaseImage(path: String, store: LauncherStore) {
        pendingApp = path
        addAfterBuild = true
        store.keepForBaseImage(path)
        store.selection = .baseImage
    }
    /// List or Rooms. Starts at the last choice.
    var libraryLayout: LibraryLayout = UIRouter.savedLayout()

    /// The user's choice: shown and kept for the next launch.
    func setLibraryLayout(_ layout: LibraryLayout) {
        libraryLayout = layout
        LauncherDefaults.store.set(layout.rawValue, forKey: SettingsKey.libraryLayout)
    }

    static func savedLayout() -> LibraryLayout {
        LauncherDefaults.store.string(forKey: SettingsKey.libraryLayout).flatMap(LibraryLayout.init(rawValue:)) ?? .list
    }
}

/// The one store, router and window opener of the process. The App scenes
/// and the AppKit delegate share them.
@MainActor
enum AppContainer {
    static let store: LauncherStore = {
        let store = LauncherStore(service: nil)
        store.welcomeDone = LauncherDefaults.welcomeDone
        return store
    }()
    static let router = UIRouter()
    /// The agent rooms. Their panes run in SwiftTerm views that outlive
    /// the views that show them (`TerminalPanes`).
    static let agents: AgentStore = {
        let agents = AgentStore(launcher: store,
                                paddockPath: { AppContainer.paddockPath },
                                makeProcess: { pane in TerminalPanes.shared.process(for: pane) })
        store.onEvent = { [weak agents] event in agents?.apply(event) }
        agents.paneClosed = { TerminalPanes.shared.remove($0) }
        // With the fallback PATH, an agent that paddock lists and this
        // launcher does not know gets its folder `~/.NAME/bin`.
        agents.agentsListed = { [weak agents] names in
            guard AppContainer.shellEnvironment.learn(agents: names) else { return false }
            agents?.use(AppContainer.shellEnvironment.current)
            return true
        }
        return agents
    }()

    /// The environment of the user's login shell, asked once per launch.
    /// An app that starts from Finder or the Dock has the PATH
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, and paddock finds no agent with
    /// it. Every paddock call and every agent pane gets the PATH of the
    /// shell and the needed variables from here.
    static let shellEnvironment: ShellEnvironment = makeShellEnvironment()

    private static func makeShellEnvironment() -> ShellEnvironment {
        let home = NSHomeDirectory()
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        // A test gives its own "shell" (a script) and its time limit.
        if let fake = environment["PADDOCK_LAUNCHER_SHELL"], !fake.isEmpty {
            let seconds = environment["PADDOCK_LAUNCHER_SHELL_SECONDS"].flatMap(Double.init) ?? ShellProbe.defaultSeconds
            return ShellEnvironment(home: home, ask: { _ in await ShellProbe(shell: fake, seconds: seconds).run() })
        }
        // A test run never starts the shell of the person at the Mac.
        if isUITest { return ShellEnvironment(home: home, ask: nil) }
        #endif
        return ShellEnvironment.live(home: home)
    }

    /// The checked paddock binary, or nil.
    static var paddockPath: String? {
        if case .found(let path, .ok) = store.binary { return path }
        return nil
    }
    /// Captured from a SwiftUI view, so AppKit code can open windows.
    static var openWindow: OpenWindowAction?
    /// The one first load. The delegate and the main window both await it,
    /// so the version alert never checks a binary that is still `checking`.
    private static var startTask: Task<Void, Never>?

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static var isUITest: Bool {
        ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_UITEST"] == "1"
    }

    static func locator() -> BinaryLocator {
        BinaryLocator(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            isDebugBuild: isDebugBuild,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            brewPrefix: { brew in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: brew)
                process.arguments = ["--prefix"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            })
    }

    /// Finds paddock and loads the state once per launch.
    static func start() async {
        let task = startTask ?? Task { await checkAgain() }
        startTask = task
        await task.value
    }

    /// `Check Again`: asks the shell for its environment again, looks for
    /// paddock again and reloads. The shell comes first, so no paddock
    /// call runs with the PATH of Finder.
    static func checkAgain() async {
        let locator = locator()
        agents.stopPolling()
        await resolveEnvironment()
        let shell = shellEnvironment
        await store.start(locate: { locator.locate() },
                          makeService: { path in
                              // The runner reads the environment at each call.
                              CLIPaddockService(runner: ProcessRunner(executable: path, environment: { shell.current.variables }))
                          })
        if store.binary.isUsable { agents.startPolling() }
    }

    /// Asks the shell again. The paddock calls and the new panes use its
    /// answer from now on.
    static func resolveEnvironment() async {
        agents.use(await shellEnvironment.refresh(chosen: LauncherDefaults.shellPath))
    }

    /// `Look again`, and a new shell in Settings: the shell once more,
    /// then `paddock list --json` with its PATH.
    static func lookAgain() async {
        await resolveEnvironment()
        await agents.loadChoices()
    }

    static func open(_ id: String) {
        openWindow?(id: id)
        NSApp.activate()
    }

    static func showMain(_ selection: SidebarItem? = nil) {
        if let selection { store.selection = selection }
        open(WindowID.main)
    }
}

enum WindowID {
    static let main = "main"
    static let onboarding = "onboarding"
}
