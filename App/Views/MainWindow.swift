import AppKit
import PaddockKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window: a sidebar (Agents, Apps, Questions, Base image) and a detail.
/// The sidebar is the only navigation. An app dropped on the window, or on
/// the Dock icon, opens the review sheet.
@MainActor
struct MainWindow: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(UIRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 320)
                // The sidebar is always there: no toggle in the title bar.
                .toolbar(removing: .sidebarToggle)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Sidebar"))
        } detail: {
            DetailRouter()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Details"))
                // The title of the window is the page, not "paddock" again:
                // the sidebar header carries the name.
                .navigationTitle(Text(windowTitle))
                .toolbar {
                    // The List / Rooms switch shows only on a page with
                    // rooms: it does nothing on Questions and Base image.
                    if ToolbarRule.showsLayoutSwitch(store.selection, apps: store.apps.count, agents: agents.rooms.count) {
                        ToolbarItem(placement: .primaryAction) { LibraryLayoutPicker() }
                    }
                    // New Agent acts on every page. It has its title next
                    // to its symbol, so nobody has to guess.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            router.sheet = .newAgent(folder: nil)
                        } label: {
                            Label("New Agent", systemImage: "plus")
                                .labelStyle(.titleAndIcon)
                        }
                        .help(Text("Start an agent on a project folder"))
                        .disabled(!store.binary.isUsable)
                        .accessibilityIdentifier("toolbar-new-agent")
                    }
                }
        }
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(Color(nsColor: .windowBackgroundColor).accessibilityHidden(true))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Main window"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The lines fade in, and the detail above gives way to them
            // in the same short move.
            VStack(spacing: 0) {
                NoticeBar()
                StreamStatusLine()
                ToastBar(toast: store.toast)
            }
            .animation(Motion.change(reduceMotion), value: store.toast?.id)
            .animation(Motion.change(reduceMotion), value: store.streamHealthy)
            .animation(Motion.change(reduceMotion), value: store.notices.first?.id)
        }
        .overlay { DropHighlight(active: dropTargeted) }
        // The room loops stop while the window is hidden or covered.
        .tracksWindowVisibility()
        .dropDestination(for: URL.self) { urls, _ in
            guard store.binary.isUsable else { return false }
            let paths = urls.filter(\.isFileURL).map(\.path)
            // A project folder starts an agent; an app goes to Add App.
            if let folder = AgentForm.droppedFolder(paths, isFolder: NewAgentSheet.isFolder) {
                router.sheet = .newAgent(folder: folder)
                return true
            }
            AddCenter.shared.receive(paths)
            return true
        } isTargeted: { dropTargeted = $0 && store.binary.isUsable }
        .sheet(item: $router.sheet) { sheet in
            MainSheetView(sheet: sheet)
                .environment(store)
                .environment(agents)
                .environment(router)
        }
        .onAppear {
            AppContainer.openWindow = openWindow
        }
        .task {
            await AppContainer.start()
            guard LaunchOnce.claim() else { return }
            SelfInstaller.offerIfNeeded()
            #if DEBUG
            // UI tests stand in for a drop: the same path as a real one.
            if let drop = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_DROP"], store.binary.isUsable {
                let paths = drop.split(separator: ":").map(String.init)
                if let folder = AgentForm.droppedFolder(paths, isFolder: NewAgentSheet.isFolder) {
                    store.selection = .agents
                    router.sheet = .newAgent(folder: folder)
                } else {
                    AddCenter.shared.receive(paths)
                }
            }
            // UI tests stand in for a click on a notification: the same
            // path as a real one. The value is `TARGET` or `TARGET;CARD`.
            if let click = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_OPEN_NOTICE"], store.binary.isUsable {
                let parts = click.split(separator: ";", maxSplits: 1).map(String.init)
                var info: [String: String] = [:]
                if let target = parts.first { info[NoticeRoute.targetKey] = target }
                if parts.count > 1 { info[NoticeRoute.cardKey] = parts[1] }
                NoticeOpener.open(userInfo: info)
            }
            #endif
        }
        .onChange(of: store.needsOnboarding, initial: true) { _, needs in
            if needs {
                openWindow(id: WindowID.onboarding)
                dismissWindow(id: WindowID.main)
            }
        }
        .onChange(of: store.apps.isEmpty, initial: true) { _, _ in
            if store.selection == nil, let first = store.apps.first { store.selection = .app(first.key) }
        }
        .onChange(of: home, initial: true) { _, home in
            if store.selection == nil, let item = home.item { store.selection = item }
        }
    }
}

extension MainWindow {
    /// The page that shows, as the title of the window.
    private var windowTitle: UIText {
        var agentTitle: UIText?
        if case .agent(let key)? = store.selection { agentTitle = agents.room(key).map { AgentCopy.title($0) } }
        return WindowTitle.of(store.selection, appTitle: store.selectedApp?.title, agentTitle: agentTitle)
    }

    /// Where a window with no app opens, once paddock listed the apps.
    private var home: HomePick {
        guard store.listLoaded, store.apps.isEmpty else { return .wait }
        switch store.golden {
        case .building, .failed: return .baseImage
        default: return agents.rooms.isEmpty ? .wait : .agents
        }
    }
}

/// The first selection of a window with no app: a base image build that
/// waits or failed, else the agents when there are runs. With neither the
/// window keeps its empty state.
enum HomePick: Equatable {
    case wait, baseImage, agents

    var item: SidebarItem? {
        switch self {
        case .wait: return nil
        case .baseImage: return .baseImage
        case .agents: return .agents
        }
    }
}

@MainActor
struct Sidebar: View {
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            AgentSidebarRows()
            Text("Apps")
                .font(.subheadline)
                .labelInk()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(Text("Apps"))
                .selectionDisabled()
            LibrarySidebarRows()
            if let pending = store.pendingAdd {
                PendingAppRow(pending: pending)
                    .selectionDisabled()
            }
            // A list row's static text is not hittable. A plain button is,
            // and it has the press action the audit requires.
            Button {
                store.selection = .questions
            } label: {
                Label { Text("Questions").labelInk() } icon: { DecorativeSymbol(name: "questionmark.bubble") }
                    .badge(store.questions.count + store.agentRequests.count)
            }
            .buttonStyle(.plain)
            .labelInk()
            .tag(SidebarItem.questions)
            .accessibilityLabel(Text("Questions"))
            .accessibilityIdentifier("sidebar-questions")
            Button {
                store.selection = .baseImage
            } label: {
                Label { Text("Base image").labelInk() } icon: { DecorativeSymbol(name: "externaldrive") }
            }
            .buttonStyle(.plain)
            .labelInk()
            .tag(SidebarItem.baseImage)
            .accessibilityLabel(Text("Base image"))
            .accessibilityIdentifier("sidebar-base-image")
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("sidebar")
        .id(store.apps.map(\.key).joined(separator: "|"))
        .onDeleteCommand {
            if let app = store.selectedApp { router.sheet = .removeApp(app.key) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrand()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Add App with its words, as Reminders has "Add List" at the
            // foot of its sidebar. A lone "+" does not say what it adds.
            HStack {
                Button {
                    router.addApp(path: nil, store: store)
                } label: {
                    Label { Text("Add App…").labelInk() } icon: { DecorativeSymbol(name: "plus.circle") }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .labelInk()
                .help(Text("Add a Mac app from your Applications folder"))
                .accessibilityLabel(Text("Add App…"))
                .accessibilityIdentifier("add-app-button")
                .disabled(!store.binary.isUsable)
                Spacer()
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }
}

/// The head of the sidebar: the paddock icon and the name. The window
/// says which app this is, on every page.
@MainActor
struct SidebarBrand: View {
    static let iconSide: CGFloat = 28

    var body: some View {
        HStack(spacing: Space.s) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: SidebarBrand.iconSide, height: SidebarBrand.iconSide)
                .accessibilityHidden(true)
            Text("paddock")
                .font(.title3.weight(.semibold))
                .labelInk()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sidebar-brand")
    }
}

/// A sidebar row: the icon with a status dot, the name, and the state
/// under the name, as UTM and Parallels list their machines.
@MainActor
struct AppRow: View {
    let app: AppItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let presentation = StatusPresentation.of(app.state, now: context.date)
            HStack(spacing: Space.s) {
                // The icon speaks the state word. It is 24 pt, large enough
                // for the hit region audit; the dot alone is not.
                AppIconWithStatus(path: app.json.bundlePath, presentation: presentation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(presentation.accessibilityLabel))
                    .accessibilityIdentifier("status-symbol-" + app.key)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.title).labelInk()
                        .lineLimit(1)
                    // Label color: secondary and vibrant primary fail the contrast audit.
                    Text(presentation.text)
                        .font(.caption)
                        .labelInk()
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("status-text-" + app.key)
                }
                Spacer(minLength: Space.xs)
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            }
            .animation(Motion.change(reduceMotion), value: presentation)
            // `.contain` keeps the status text and symbol as children with
            // their identifiers; the row still speaks name, text and state.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: RowSpeech.of(app.title, presentation)))
            .accessibilityIdentifier("app-row-" + app.key)
        }
    }
}

/// The spoken line of an app row: `Sample Notes, Running, 3 windows`. The
/// state word comes first, then the detail of the row text.
enum RowSpeech {
    static func of(_ title: String, _ presentation: StatusPresentation) -> String {
        let label = presentation.accessibilityLabel.localized
        let text = presentation.text.localized
        var parts = [title, label]
        // `Running · 3 windows` adds `3 windows`; a text that is the label
        // again, or holds it, adds nothing.
        let detail = text.components(separatedBy: " · ").dropFirst().joined(separator: ", ")
        if !detail.isEmpty {
            parts.append(detail)
        } else if !label.contains(text), text != label {
            parts.append(text)
        }
        return parts.joined(separator: ", ")
    }
}

@MainActor
struct AppRowMenu: View {
    let app: AppItem
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        ForEach(SessionButtons.of(app.state, canSuspend: store.capabilities.suspend), id: \.self) { button in
            Button(SessionMenuTitle.of(button)) { SessionCommand.perform(button, app, store: store, router: router) }
        }
        Button("Open New Instance") { SessionCommand.newInstance(app, store: store) }
            .disabled(app.state.isBlocked)
        Divider()
        Button("Remove App…") { router.sheet = .removeApp(app.key) }
    }
}

/// The detail for the sidebar selection. In the Rooms layout an app
/// selection shows the grid of rooms, with that room selected.
///
/// A change between List and Rooms fades the new view in (`Motion.enter`);
/// the old one goes at once, so the two never share the window.
@MainActor
struct DetailRouter: View {
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            content
        }
        .animation(Motion.change(reduceMotion), value: router.libraryLayout)
    }

    @ViewBuilder private var content: some View {
        if store.selection?.isAgents == true, store.binary != .checking {
            // The agents do not wait for the app list.
            AgentsDetail()
                .transition(Motion.enter)
        } else if store.binary == .checking || (store.binary.isUsable && !store.listLoaded && store.listError == nil) {
            LibraryStateView(kind: .loading)
        } else if !store.binary.isUsable, store.apps.isEmpty {
            LibraryStateView(kind: .offline)
        } else if let line = store.listError, store.apps.isEmpty {
            LibraryStateView(kind: .failed(line))
        } else {
            selected
        }
    }

    @ViewBuilder private var selected: some View {
        switch store.selection {
        case .app(let name)?:
            if store.app(named: name) == nil {
                // The app left the list. The store moves the selection to
                // the next row; until then, the state of the section.
                if store.apps.isEmpty { EmptyAppsView() } else { SelectAppView() }
            } else if router.libraryLayout == .rooms {
                LibraryRoomsView()
                    .transition(Motion.enter)
            } else {
                AppDetailView(name: name)
                    .id(name)
                    .transition(Motion.enter)
            }
        case .questions?:
            QuestionsView()
        case .baseImage?:
            BaseImageView()
        case .agents?, .agent?:
            AgentsDetail()
        case nil:
            if store.apps.isEmpty {
                EmptyAppsView()
            } else if router.libraryLayout == .rooms {
                LibraryRoomsView()
                    .transition(Motion.enter)
            } else {
                SelectAppView()
            }
        }
    }
}

/// No app is selected, and there are apps: the home page. It says where
/// things stand and what to do next, with the room art. Never an empty
/// detail.
@MainActor
struct SelectAppView: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(UIRouter.self) private var router

    var body: some View {
        let waiting = store.questions.count + store.agentRequests.count
        let next = NextStep.of(waiting: waiting, agents: agents.rooms.count, apps: store.apps.count)
        PlainEmpty {
            VStack(spacing: Space.l) {
                StagedRoom(scene: .empty, icon: .image(NSApp.applicationIconImage), side: RoomSize.welcome)
                VStack(spacing: Space.xs) {
                    Text(next.title).font(.title2.bold())
                    if let summary = NextStep.summary(agents: agents.rooms.count, apps: store.apps.count) {
                        Text(summary).font(.callout).labelInk()
                    }
                }
            }
        } description: {
            Text("Choose an app in the sidebar to see its room, or add another app.")
        } actions: {
            VStack(spacing: Space.m) {
                HomeNextButton(next: next)
                Button("Add App…") { router.addApp(path: nil, store: store) }
                    .disabled(!store.binary.isUsable)
                    .accessibilityIdentifier("select-add-app")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Select an app"))
        .accessibilityIdentifier("select-app")
    }
}

/// The prominent action of the home page: the requests that wait, else
/// New Agent.
@MainActor
struct HomeNextButton: View {
    let next: NextStep
    var identifier = "home-next"
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        Button {
            switch next {
            case .answer: store.selection = .questions
            case .firstAgent, .newAgent: router.sheet = .newAgent(folder: nil)
            }
        } label: {
            Text(next.action)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!store.binary.isUsable)
        .accessibilityIdentifier(identifier)
    }
}

/// The app that waits for the base image, under the apps of the sidebar:
/// its icon, its name and what it waits for. A click shows its room with
/// the build, on the Base image page.
@MainActor
struct PendingAppRow: View {
    let pending: PendingAdd
    @Environment(LauncherStore.self) private var store

    var body: some View {
        let status = pending.status(golden: store.golden)
        Button {
            store.selection = .baseImage
        } label: {
            HStack(spacing: Space.s) {
                AppIcon(path: pending.path)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: pending.title).labelInk().lineLimit(1)
                    Text(status).font(.caption).labelInk().lineLimit(1)
                }
                Spacer(minLength: Space.xs)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: pending.title + ", " + status.localized))
        .accessibilityIdentifier("pending-app-row")
    }
}

/// Nothing to show for the Apps section. In a window with no agent run
/// either, the agent comes first: its room, one sentence and the one
/// prominent action, New Agent. The Mac apps are the quiet second choice.
/// With agent runs, the page is only about the apps.
@MainActor
struct EmptyAppsView: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(UIRouter.self) private var router

    private var agentFirst: Bool { agents.rooms.isEmpty }

    var body: some View {
        PlainEmpty {
            VStack(spacing: Space.l) {
                if agentFirst {
                    StagedRoom(scene: .empty, icon: .image(AgentScreen.image(RoomScene.empty.color)),
                               side: RoomSize.welcome)
                    VStack(spacing: Space.xs) {
                        // The first page of the product says its name.
                        Text("Welcome to paddock").font(.callout.weight(.semibold)).labelInk()
                        Text("Start your first agent").font(.title2.bold())
                    }
                } else {
                    StagedRoom(scene: .empty, icon: .image(NSApp.applicationIconImage), side: RoomSize.welcome)
                    Text("No apps yet").font(.title2.bold())
                }
            }
        } description: {
            if agentFirst {
                Text("Start Claude Code, Codex or another coding agent on a project folder. It works in a sandbox, and you answer what it asks here.")
            } else {
                Text("Add an app from your Applications folder. It runs in its own sandbox the next time you start it.")
            }
        } actions: {
            VStack(spacing: Space.m) {
                if agentFirst {
                    Button("New Agent…") { router.sheet = .newAgent(folder: nil) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.binary.isUsable)
                        .accessibilityIdentifier("empty-new-agent")
                    Divider().frame(width: 220).padding(.vertical, Space.s)
                    Text("No apps yet").font(.headline)
                    Text("A Mac app can get a room too.").font(.callout).labelInk()
                    Button("Add App…") { router.addApp(path: nil, store: store) }
                        .disabled(!store.binary.isUsable)
                        .accessibilityIdentifier("empty-add-app")
                } else {
                    Button("Add App…") { router.addApp(path: nil, store: store) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!store.binary.isUsable)
                        .accessibilityIdentifier("empty-add-app")
                }
                Text(LibraryCopy.dropHint).font(.callout).labelInk()
            }
        }
        // Without `.contain` the identifier goes to every child and hides
        // `empty-add-app`.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(agentFirst ? Text("Start your first agent") : Text("No apps yet"))
        .accessibilityIdentifier("empty-state")
    }
}

/// The sheet for the router's current sheet.
@MainActor
struct MainSheetView: View {
    let sheet: MainSheet

    var body: some View {
        switch sheet {
        case .addApp(let path): AddReviewSheet(initialPath: path)
        case .newAgent(let folder): NewAgentSheet(initialFolder: folder)
        case .confirmStopAgent(let key): ConfirmStopAgentSheet(key: key)
        case .removeApp(let name): RemoveAppSheet(name: name)
        case .confirmStop(let name): ConfirmStopSheet(name: name)
        case .clearState(let name): ClearStateSheet(name: name)
        case .uninstall: UninstallSheet()
        case .removeGolden: RemoveGoldenSheet()
        case .rebuild: RebuildSheet()
        case .cancelBuild: CancelBuildSheet()
        }
    }
}

/// The menu titles of the session buttons.
enum SessionMenuTitle {
    static func of(_ button: SessionButtons) -> LocalizedStringKey {
        switch button {
        case .start: return "Start" // localized
        case .resume: return "Resume" // localized
        case .open: return "Open" // localized
        case .suspend: return "Suspend" // localized
        case .stop: return "Stop" // localized
        }
    }
}
