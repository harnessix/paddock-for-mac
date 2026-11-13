import Foundation

/// One tile of the agent grid of the New Agent sheet.
public struct AgentChoice: Equatable, Sendable, Identifiable {
    public var harness: String
    public var title: String
    public var color: CharacterColor
    public var installed: Bool
    /// The command that installs the agent: the one of its profile in
    /// paddock's list, else the one its maker documents. nil when the
    /// agent is installed or no command is known.
    public var install: String?
    /// What to do when the agent is not installed: run `install`, or
    /// install it by hand when no command is known.
    public var hint: UIText?

    public var id: String { harness }

    /// The spoken label of the tile: `Claude Code, installed`.
    public var spoken: UIText {
        installed ? UIText("%@, installed", title) : UIText("%@, not installed", title)
    }
}

/// One folder of the New Agent sheet.
public struct FolderChoice: Equatable, Sendable, Identifiable {
    public var path: String
    /// The last agent paddock ran there, when it says.
    public var harness: String?
    public var last: Date?

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }

    public init(path: String, harness: String? = nil, last: Date? = nil) {
        self.path = path
        self.harness = harness
        self.last = last
    }
}

/// The New Agent sheet: the agent, the project folder and two options.
/// The sheet view binds to it; every rule is here, so it tests on Linux.
public struct AgentForm: Equatable, Sendable {
    public var choices: [AgentChoice]
    public var folders: [FolderChoice]
    public var harness: String?
    public var folder: String?
    public var network: AgentNetwork
    public var worktree: Bool
    public var mode: AgentMode = AgentMode.initial
    /// The mode of the last start of each agent that has one.
    public var modes: [String: AgentMode]
    /// The mode of an agent that has none in `modes`.
    public var fallbackMode: AgentMode
    /// True once you chose the mode in this form. A change of the agent
    /// then leaves it.
    public private(set) var modeChosen = false
    /// True when the chosen folder is in a git repository: only then the
    /// sheet offers "Work in a new branch".
    public var isGitProject: Bool

    /// The most recent folders the sheet lists.
    public static let maxFolders = 8

    public init(harnesses: [HarnessJSON], recents: [RecentProjectJSON], network: AgentNetwork = .api,
                mode: AgentMode = AgentMode.initial, modes: [String: AgentMode] = [:],
                preferredHarness: String? = nil, folder: String? = nil) {
        let agents = AgentCharacter.sorted(harnesses.filter { !$0.app })
        choices = agents.map { h in
            let install = h.installed ? nil : (h.install ?? AgentInstall.command(h.name))
            return AgentChoice(harness: h.name, title: AgentCharacter.title(h.name, summary: h.summary),
                               color: AgentCharacter.color(h.name), installed: h.installed, install: install,
                               hint: h.installed ? nil : AgentCopy.installHint(command: install != nil))
        }
        folders = Array(recents.prefix(AgentForm.maxFolders)).map { FolderChoice(path: $0.path, harness: $0.harness, last: $0.last) }
        self.network = network
        self.modes = modes
        fallbackMode = mode
        worktree = false
        isGitProject = false
        // The agent: the one asked for, else the agent of the last
        // project, else the first installed one.
        let installed = choices.filter(\.installed).map(\.harness)
        if let preferredHarness, installed.contains(preferredHarness) {
            harness = preferredHarness
        } else if let last = recents.first?.harness, installed.contains(last) {
            harness = last
        } else {
            harness = installed.first
        }
        self.mode = harness.flatMap { modes[$0] } ?? mode
        self.folder = nil
        if let folder { choose(folder: folder) }
    }

    /// The tiles of the grid: the installed agents, in the sheet's order.
    public var installedChoices: [AgentChoice] { choices.filter(\.installed) }

    /// The agents under "More agents (not installed)", each with its
    /// install command or hint.
    public var otherChoices: [AgentChoice] { choices.filter { !$0.installed } }

    /// The recent folders that the sheet shows as rows. The sheet has room
    /// for `shownFolderCount`; the chosen folder is always one of them.
    /// The rest are in `moreFolders`, a menu.
    public var shownFolders: [FolderChoice] {
        var shown = Array(folders.prefix(AgentForm.shownFolderCount))
        if let folder, !shown.contains(where: { $0.path == folder }),
           let chosen = folders.first(where: { $0.path == folder }), !shown.isEmpty {
            shown[shown.count - 1] = chosen
        }
        return shown
    }

    /// The recent folders that are not rows.
    public var moreFolders: [FolderChoice] {
        let shown = Set(shownFolders.map(\.path))
        return folders.filter { !shown.contains($0.path) }
    }

    /// The folder rows of the sheet. With more, the folder, the mode and
    /// Start no longer show without a scroll at the default window size.
    public static let shownFolderCount = 3

    /// Picks a folder: from the list, a drop or Choose Folder…. A folder
    /// that is not in the list goes on top of it.
    public mutating func choose(folder path: String, isGit: Bool = false) {
        let clean = AgentForm.normalize(path)
        if !folders.contains(where: { $0.path == clean }) {
            folders.insert(FolderChoice(path: clean), at: 0)
        }
        folder = clean
        isGitProject = isGit
        if !isGit { worktree = false }
    }

    /// Picks an agent. A tile of an agent that is not installed does not.
    public mutating func choose(harness name: String) {
        guard choices.contains(where: { $0.harness == name && $0.installed }) else { return }
        harness = name
        // The mode of the last start of this agent, until you choose one here.
        if !modeChosen { mode = modes[name] ?? fallbackMode }
    }

    /// Picks how the agent works. The choice stays when the agent changes.
    public mutating func choose(mode: AgentMode) {
        self.mode = mode
        modeChosen = true
    }

    public mutating func setGitProject(_ isGit: Bool) {
        isGitProject = isGit
        if !isGit { worktree = false }
    }

    /// Why Start is off, or nil when it can start.
    public var missing: UIText? {
        if choices.isEmpty { return UIText("paddock lists no agents.") }
        if !choices.contains(where: \.installed) { return UIText("No agent is installed yet.") }
        if harness == nil { return UIText("Choose an agent.") }
        if folder == nil { return UIText("Choose a project folder.") }
        return nil
    }

    public var canStart: Bool { missing == nil }

    /// The run of the sheet, or nil when it cannot start.
    public var launch: AgentLaunch? {
        guard canStart, let harness, let folder else { return nil }
        return AgentLaunch(harness: harness, folder: folder, network: network, worktree: worktree && isGitProject,
                           mode: mode)
    }

    /// `/Users/u/src/app/` → `/Users/u/src/app`.
    public static func normalize(_ path: String) -> String {
        var clean = (path as NSString).standardizingPath
        while clean.count > 1, clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }

    /// True when `folder` or a folder above it has `.git`: a git checkout
    /// or a worktree. `exists` checks one path.
    public static func isGit(_ folder: String, exists: (String) -> Bool) -> Bool {
        var current = normalize(folder)
        while true {
            if exists((current as NSString).appendingPathComponent(".git")) { return true }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    /// The folder of a drop: the one path that is a folder and not an app
    /// bundle. `isFolder` checks one path.
    public static func droppedFolder(_ paths: [String], isFolder: (String) -> Bool) -> String? {
        let folders = paths.filter { !$0.lowercased().hasSuffix(".app") && isFolder($0) }
        return folders.count == 1 ? normalize(folders[0]) : nil
    }
}

/// The texts of the agent rooms that take values.
public enum AgentCopy {
    /// The agent has an install command: it shows under this line, with Copy.
    public static let installHintCommand = UIText("Not installed. Run this command in Terminal, then reopen this sheet:")
    /// No install command is known for this agent: neither paddock's list
    /// (a field `install`, which paddock 0.2.4 does not have) nor the
    /// launcher's table has one.
    public static let installHintManual = UIText("Not installed. Install it in Terminal, then reopen this sheet.")

    /// The hint of an agent that is not installed.
    public static func installHint(command: Bool) -> UIText {
        command ? installHintCommand : installHintManual
    }

    /// The disclosure of the agents that are not installed.
    public static let moreAgents = UIText("More agents (not installed)")
    /// The first line under it, in the sheet.
    public static let installIntro = UIText("To install an agent, run its command in Terminal, then reopen this sheet.")
    /// The first line under it, in step 3 of the welcome window.
    public static let installIntroWelcome = UIText("To install an agent, run its command in Terminal, then click Look again in step 2.")
    /// An agent with no command, in the welcome window.
    public static let installHintManualWelcome = UIText("Not installed. Install it in Terminal.")
    /// The menu of the recent folders that are no rows of the sheet.
    public static let moreFolders = UIText("Other Recent Projects")

    /// `Claude Code in my-app`.
    public static func title(_ room: AgentRoom) -> UIText {
        UIText("%@ in %@", room.title, room.projectText)
    }

    /// The tag of a run in full auto, on its room and in its detail. A
    /// run in manual mode, the default, has no tag.
    public static let autoTag = UIText("auto")

    /// The spoken line of a room or a row: `Claude Code in my-app, Waiting
    /// for you, 2 requests`.
    public static func spoken(_ room: AgentRoom) -> String {
        spokenText(room).english
    }

    /// The spoken line as a text, for the language of the interface.
    public static func spokenText(_ room: AgentRoom) -> UIText {
        var parts = [title(room), room.stateWord]
        if room.manual { parts.append(UIText("asks before each step")) }
        if room.auto { parts.append(UIText("works on its own")) }
        if case .waiting(let count) = room.state {
            parts.append(count == 1 ? UIText("1 request") : UIText("%lld requests", count))
        }
        if case .failed(let reason?) = room.state { parts.append(UIText.cli(reason, else: StatusPresentation.seeDetails)) }
        if let branch = room.branch { parts.append(UIText("branch %@", branch)) }
        return UIText.list(parts)
    }

    /// `12 min`, `2 h 5 min`: how long the run ran.
    public static func duration(from start: Date, to end: Date) -> UIText {
        let minutes = Int(max(0, end.timeIntervalSince(start)) / 60)
        if minutes < 1 { return UIText("less than a minute") }
        if minutes < 60 { return UIText("%@ min", "\(minutes)") }
        return UIText("%@ h %@ min", "\(minutes / 60)", "\(minutes % 60)")
    }

    /// The files line of the detail.
    public static func files(_ count: Int?) -> UIText {
        guard let count else { return needs("paddock ps --json", field: "files_changed") }
        switch count {
        case 0: return UIText("No files changed")
        case 1: return UIText("1 file changed")
        default: return UIText("%lld files changed", count)
        }
    }

    /// The "needs paddock X" line of a command or a field that paddock does
    /// not have yet.
    public static func needs(_ command: String, field: String? = nil) -> UIText {
        if let field { return UIText("Needs a paddock with %@ in %@", field, command) }
        return UIText("Needs a paddock with %@", command)
    }
}
