import AppKit
import PaddockKit
import SwiftUI

/// New Agent: the agent, the project folder, two plain options and one
/// button, Start. The same sheet for the toolbar button, File > New Agent…,
/// ⌘N in the Agents section, and a folder dropped on the sheet, the
/// window or the Dock icon.
@MainActor
struct NewAgentSheet: View {
    let initialFolder: String?
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var form = AgentForm(harnesses: [], recents: [])
    @State private var loaded = false
    @State private var dropTargeted = false

    /// Five tiles in a row of the sheet: the agents take one row, and the
    /// folder, the mode and Start show without a scroll.
    static let columns = [GridItem(.adaptive(minimum: 92, maximum: 140), spacing: Space.s)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                NewAgentFields(form: $form, loaded: loaded)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error = agents.lastError {
                    ProblemLine {
                        Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("new-agent-error")
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.canStart)
                    .accessibilityIdentifier("new-agent-start")
            }
            .padding(Space.l)
        }
        .frame(width: 560)
        // The default main window is 620 pt high: the sheet fits in it.
        .frame(minHeight: 520, idealHeight: 590)
        .overlay { DropHighlight(active: dropTargeted) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = AgentForm.droppedFolder(urls.filter(\.isFileURL).map(\.path), isFolder: NewAgentSheet.isFolder)
            else { return false }
            form.choose(folder: folder, isGit: NewAgentSheet.isGit(folder))
            return true
        } isTargeted: { dropTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("New Agent"))
        .accessibilityIdentifier("new-agent-sheet")
        .task {
            form = await NewAgentActions.load(agents: agents, store: store, folder: initialFolder ?? form.folder)
            loaded = true
        }
    }

    private func start() {
        // The pane shows at once: List shows a selected room directly.
        if NewAgentActions.start(form, agents: agents, store: store) != nil { dismiss() }
    }

    nonisolated static func isGit(_ folder: String) -> Bool {
        AgentForm.isGit(folder) { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

/// What the New Agent sheet and the welcome window do with the form: load
/// it from paddock's lists and the last choices, and start the run.
@MainActor
enum NewAgentActions {
    /// The form with paddock's agents and recent projects, the network
    /// level of the last start, the mode of the last start of each agent,
    /// and `folder` chosen. An agent with no start yet asks before each
    /// step (`AgentMode.initial`).
    static func load(agents: AgentStore, store: LauncherStore, folder: String?) async -> AgentForm {
        if !agents.harnessesLoaded || agents.recents.isEmpty { await agents.loadChoices() }
        let preferred: String?
        if case .agent(let key)? = store.selection { preferred = agents.room(key)?.harness } else { preferred = nil }
        let defaults = LauncherDefaults.store
        let saved: (String) -> String? = { defaults.string(forKey: $0) }
        var next = AgentForm(harnesses: agents.harnesses, recents: agents.recents,
                             network: AgentNetwork(rawValue: defaults.string(forKey: SettingsKey.agentNetwork) ?? "")
                                 ?? .api,
                             mode: AgentModeMemory.fallback(read: saved),
                             modes: AgentModeMemory.modes(agents.harnesses.map(\.name), read: saved),
                             preferredHarness: preferred)
        if let folder {
            next.choose(folder: folder, isGit: NewAgentSheet.isGit(folder))
        }
        return next
    }

    /// Starts the run of the form in a pane and selects its room. Nil
    /// when the form cannot start or paddock is not there; the reason is
    /// then in `agents.lastError`.
    static func start(_ form: AgentForm, agents: AgentStore, store: LauncherStore) -> String? {
        guard let launch = form.launch else { return nil }
        agents.lastError = nil
        LauncherDefaults.store.set(launch.network.rawValue, forKey: SettingsKey.agentNetwork)
        // The mode of this agent only: full auto for one agent is no
        // choice for the others.
        LauncherDefaults.store.set(launch.mode.rawValue, forKey: AgentModeMemory.key(launch.harness))
        guard let key = agents.start(launch) else { return nil }
        store.selection = .agent(key)
        // The pane opens in the Rooms layout too, not only its card.
        store.openRoom = .agent(key)
        return key
    }
}

/// The sections of New Agent: the agent, the project folder, how the
/// agent works and the network. They go in a grouped `Form`: in the New
/// Agent sheet, and in step 3 of the welcome window.
@MainActor
struct NewAgentFields: View {
    @Binding var form: AgentForm
    let loaded: Bool
    /// The welcome window: a drop goes on the window, and the reason
    /// Start is off shows next to Start.
    var welcome = false
    @Environment(AgentStore.self) private var agents
    /// "More agents (not installed)" is open. It is always open when no
    /// agent is installed: then it holds every agent.
    @State private var othersOpen = false

    var body: some View {
        agentSection
        folderSection
        modeSection
        optionsSection
        // The welcome window says it next to Start, where it stays in view.
        if !welcome, let missing = NewAgentFields.missing(form, loaded: loaded) {
            Section {
                Text(missing).font(.callout).labelInk().accessibilityIdentifier("new-agent-missing")
            }
        }
    }

    /// Why Start is off, once the agents are known. Nil while the form
    /// loads and when paddock lists no agent: the Agent section says that.
    static func missing(_ form: AgentForm, loaded: Bool) -> UIText? {
        guard loaded, !form.choices.isEmpty else { return nil }
        return form.missing
    }

    @ViewBuilder private var agentSection: some View {
        Section {
            if !loaded {
                ProgressView { Text("Looking for agents…") }
            } else if agents.gaps.contains(.list) {
                Text(AgentGap.list.line).labelInk().accessibilityIdentifier("new-agent-needs-list")
            } else if form.choices.isEmpty {
                Text("paddock lists no agents.").labelInk()
            } else {
                // The installed agents, the only ones that can start.
                if !form.installedChoices.isEmpty {
                    LazyVGrid(columns: NewAgentSheet.columns, alignment: .leading, spacing: Space.s) {
                        ForEach(form.installedChoices) { choice in
                            AgentChoiceTile(choice: choice, selected: form.harness == choice.harness) {
                                form.choose(harness: choice.harness)
                            }
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                if !form.otherChoices.isEmpty {
                    DisclosureGroup(isExpanded: othersExpanded) {
                        VStack(alignment: .leading, spacing: Space.m) {
                            Text(welcome ? AgentCopy.installIntroWelcome : AgentCopy.installIntro)
                                .font(.callout)
                                .labelInk()
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(form.otherChoices) { choice in
                                AgentInstallRow(choice: choice, welcome: welcome)
                            }
                        }
                        .padding(.vertical, Space.xs)
                    } label: {
                        Text(AgentCopy.moreAgents).labelInk()
                    }
                    .accessibilityIdentifier("new-agent-more-agents")
                }
            }
        } header: {
            Text("Agent")
        }
    }

    private var othersExpanded: Binding<Bool> {
        Binding(get: { othersOpen || form.installedChoices.isEmpty }, set: { othersOpen = $0 })
    }

    @ViewBuilder private var folderSection: some View {
        Section {
            ForEach(form.shownFolders) { folder in
                ChoiceRow(title: Text(verbatim: folder.name),
                          detail: Text(verbatim: Format.tildePath(folder.path, home: NSHomeDirectory())),
                          spoken: folder.name + ", " + Format.tildePath(folder.path, home: NSHomeDirectory()),
                          selected: form.folder == folder.path) {
                    choose(folder.path)
                }
                .accessibilityIdentifier("new-agent-folder-" + folder.name)
            }
            if form.folders.isEmpty {
                Text("No recent projects. Choose a folder, or drop one here.").labelInk()
            }
            HStack(spacing: Space.s) {
                Button("Choose Folder…") {
                    if let path = Pickers.folder(start: form.folder ?? NSHomeDirectory()) { choose(path) }
                }
                .fixedSize()
                .accessibilityIdentifier("new-agent-choose-folder")
                // The recent folders that have no row.
                if !form.moreFolders.isEmpty {
                    Menu {
                        ForEach(form.moreFolders) { folder in
                            Button {
                                choose(folder.path)
                            } label: {
                                Text(verbatim: folder.name + " · " + Format.tildePath(folder.path, home: NSHomeDirectory()))
                            }
                            .accessibilityIdentifier("new-agent-folder-" + folder.name)
                        }
                    } label: {
                        Text(AgentCopy.moreFolders)
                    }
                    .fixedSize()
                    .accessibilityIdentifier("new-agent-more-folders")
                }
                Spacer(minLength: Space.s)
                (welcome ? Text("Or drop a folder on this window.") : Text("Or drop a folder on this sheet."))
                    .font(.caption).labelInk()
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if agents.gaps.contains(.recent) {
                Text(AgentGap.recent.line).font(.caption).labelInk()
            }
        } header: {
            Text("Project folder")
        }
    }

    @ViewBuilder private var modeSection: some View {
        Section {
            // Manual comes first, and neither mode is recommended.
            ForEach(AgentMode.manualFirst) { mode in
                ChoiceRow(title: Text(mode.title), detail: Text(mode.detail),
                          spoken: mode.title.localized + ", " + mode.detail.localized,
                          selected: form.mode == mode) {
                    form.choose(mode: mode)
                }
                .accessibilityIdentifier("new-agent-mode-" + mode.rawValue)
            }
        } header: {
            Text("How the agent works")
        }
    }

    @ViewBuilder private var optionsSection: some View {
        Section {
            ForEach(AgentNetwork.allCases) { level in
                ChoiceRow(title: Text(level.title), detail: Text(level.detail),
                          spoken: level.title.localized + ", " + level.detail.localized,
                          selected: form.network == level) {
                    form.network = level
                }
                .accessibilityIdentifier("new-agent-network-" + level.rawValue)
            }
            Toggle(isOn: $form.worktree) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Work in a new branch")
                    Text(form.isGitProject
                         ? UIText("The agent works in its own copy of the project. You review its changes before they reach your branch.")
                         : UIText("Only for a project in git."))
                        .font(.caption)
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!form.isGitProject)
            .accessibilityIdentifier("new-agent-worktree")
        } header: {
            Text("Options")
        }
    }

    private func choose(_ path: String) {
        form.choose(folder: path, isGit: NewAgentSheet.isGit(path))
    }
}

/// One agent under "More agents (not installed)": its character asleep,
/// its name, and its install command with Copy. Without a command, the
/// line that says how to install it. It is no choice: no button.
@MainActor
struct AgentInstallRow: View {
    let choice: AgentChoice
    var welcome = false

    static let side: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            RoomView(scene: RoomScene(tint: .cream, color: choice.color, pose: .sleep),
                     icon: .image(AgentScreen.image(choice.color)), side: AgentInstallRow.side)
                .frame(width: AgentInstallRow.side, height: AgentInstallRow.side)
                .saturation(0)
                .opacity(0.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: choice.title).labelInk()
                if let command = choice.install {
                    CopyField(command: command)
                } else if let hint = welcome ? AgentCopy.installHintManualWelcome : choice.hint {
                    Text(hint).font(.caption).labelInk().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(choice.spoken))
        .accessibilityIdentifier("new-agent-choice-" + choice.harness)
    }
}

/// One installed agent of the sheet: its character and its name. One
/// element, a button.
@MainActor
struct AgentChoiceTile: View {
    let choice: AgentChoice
    let selected: Bool
    let choose: () -> Void

    static let side: CGFloat = 52

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Space.xs) {
                RoomView(scene: RoomScene(tint: .cream, color: choice.color, pose: choice.installed ? .idle : .sleep),
                         icon: .image(AgentScreen.image(choice.color)), side: AgentChoiceTile.side)
                    .frame(width: AgentChoiceTile.side, height: AgentChoiceTile.side)
                    // Greyed out: the room, not the words, which must stay readable.
                    .saturation(choice.installed ? 1 : 0)
                    .opacity(choice.installed ? 1 : 0.5)
                Text(verbatim: choice.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .labelInk()
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if !choice.installed {
                    Text("Not installed").font(.caption).labelInk()
                }
            }
            .padding(Space.s)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Radius.banner, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.banner, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!choice.installed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(choice.spoken))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("new-agent-choice-" + choice.harness)
    }
}

/// One choice of a list in the sheet: a radio mark, a title and a line
/// under it. One element: its spoken line, and selected when chosen.
@MainActor
struct ChoiceRow: View {
    let title: Text
    let detail: Text
    let spoken: String
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    title.labelInk()
                    detail.font(.caption).labelInk().lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
