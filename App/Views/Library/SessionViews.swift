import PaddockKit
import SwiftUI

/// The apps of the sidebar: one row per app. An app with more than one
/// instance gets a header row, then every instance. A disclosure group
/// hides the first instance from the accessibility tree, so the rows stay
/// expanded.
@MainActor
struct LibrarySidebarRows: View {
    @Environment(LauncherStore.self) private var store

    var body: some View {
        ForEach(InstanceGroup.groups(store.apps)) { group in
            if group.isGroup {
                HStack(spacing: Space.s) {
                    AppIcon(path: group.items.first?.json.bundlePath)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: group.title).labelInk()
                        Text(group.countText).font(.caption).labelInk()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: group.title))
                .accessibilityIdentifier("app-group-" + group.app)
                .selectionDisabled()
            }
            ForEach(group.items) { item in row(item) }
        }
    }

    private func row(_ item: AppItem) -> some View {
        AppRow(app: item)
            .tag(SidebarItem.app(item.key))
            .contextMenu { AppRowMenu(app: item) }
    }
}

/// The session buttons of an app: Start, Resume, Open, Suspend, Stop, and
/// Open New Instance. The same rules in the header, the menu bar and the
/// context menu.
enum SessionButtons {
    case start, resume, open, suspend, stop

    static func of(_ state: AppState, canSuspend: Bool) -> [SessionButtons] {
        var list: [SessionButtons] = []
        if state.canStart { list.append(.start) }
        if state.canResume { list.append(.resume) }
        if state.isRunning { list.append(.open) }
        if state.isRunning, canSuspend { list.append(.suspend) }
        if state.canStop { list.append(.stop) }
        return list
    }

    /// The primary button of a list: Start, Resume or Open. Suspend and
    /// Stop are never primary.
    static func primary(of list: [SessionButtons]) -> SessionButtons? {
        list.first { $0 != .stop && $0 != .suspend }
    }
}

/// Runs a session button. Open activates the session's Dock app; when it
/// is not found, paddock's `app run` brings the session forward.
@MainActor
enum SessionCommand {
    static func perform(_ button: SessionButtons, _ app: AppItem, store: LauncherStore, router: UIRouter) {
        switch button {
        case .start, .resume:
            Task { await store.startApp(app.key) }
        case .open:
            if !SessionActivator.activate(app) { Task { await store.startApp(app.key) } }
        case .suspend:
            Task { await store.suspend(app.key) }
        case .stop:
            // Only open questions make Stop ask first.
            if store.questions.contains(where: { $0.app == app.name }) {
                router.sheet = .confirmStop(app.key)
            } else {
                Task { await store.stopApp(app.key) }
            }
        }
    }

    static func newInstance(_ app: AppItem, store: LauncherStore) {
        Task { await store.launchNewInstance(app.key) }
    }
}

/// The hero of an app's detail: the room of the app with the real icon on
/// its laptop screen, the name, the bundle path and the state. Then the
/// actions: Suspend and Stop first, the one prominent action last, and a
/// menu with Open New Instance and Remove.
///
/// The prominent action comes from `HeroAction`: Start, Resume or Open.
/// While the base image is missing it says so and leads to its page, in
/// place of a Start that cannot work.
@MainActor
struct SessionHeader: View {
    let app: AppItem
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        let buttons = SessionButtons.of(app.state, canSuspend: store.capabilities.suspend)
        let hero = HeroAction.of(app.state, golden: store.golden, goldenLoaded: store.goldenLoaded)
        HStack(alignment: .center, spacing: Space.xl) {
            StagedRoom(scene: store.roomScene(app), icon: .app(path: app.json.bundlePath), side: RoomSize.header,
                       world: RoomWorld.of(app, questions: store.questionCount(app)), zoom: .target(app.key))
            VStack(alignment: .leading, spacing: Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.title).font(.title.bold()).labelInk()
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("detail-title")
                    if let path = app.json.bundlePath {
                        Text(verbatim: Format.tildePath(path, home: NSHomeDirectory()))
                            .font(.callout)
                            .labelInk()
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let presentation = StatusPresentation.of(app.state, now: context.date)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        StatusPill(presentation: presentation)
                            .accessibilityIdentifier("detail-status")
                        // The reason of an error or a block, in the words of
                        // this language. The note of the action says the
                        // same for a missing base image.
                        if hero?.note == nil, let reason = HeroCopy.reason(presentation) {
                            DetailedText(reason, id: "detail-reason")
                                .font(.callout)
                                .labelInk()
                        }
                    }
                }
                if let note = hero?.note {
                    Text(note)
                        .font(.callout)
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("hero-note")
                }
            }
            Spacer(minLength: Space.m)
            // Secondary buttons first, the prominent one last: the eye ends on it.
            ForEach(buttons.filter { $0 == .suspend || $0 == .stop }, id: \.self) { button in
                secondaryButton(button)
            }
            if let hero {
                heroButton(hero)
            }
            Menu {
                Button("Open New Instance") { SessionCommand.newInstance(app, store: store) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(app.state.isBlocked || !store.binary.isUsable)
                Divider()
                Button("Remove App…") { router.sheet = .removeApp(app.key) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .fixedSize()
            .menuAuditAction()
            .help(Text("More actions for this app"))
            .accessibilityLabel(Text("More"))
            .accessibilityIdentifier("detail-more")
        }
    }

    /// The one prominent button of the page: large, in the accent color,
    /// and the default action.
    private func heroButton(_ hero: HeroAction) -> some View {
        Button {
            switch hero {
            case .start: SessionCommand.perform(.start, app, store: store, router: router)
            case .resume: SessionCommand.perform(.resume, app, store: store, router: router)
            case .open: SessionCommand.perform(.open, app, store: store, router: router)
            case .buildBaseImage, .showBuild: store.selection = .baseImage
            }
        } label: {
            Text(hero.title).frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!store.binary.isUsable && hero != .open)
        .accessibilityIdentifier(hero.identifier)
    }

    @ViewBuilder
    private func secondaryButton(_ button: SessionButtons) -> some View {
        let action = { SessionCommand.perform(button, app, store: store, router: router) }
        Group {
            if button == .suspend {
                Button("Suspend", action: action)
                    .accessibilityIdentifier("suspend-button")
            } else {
                Button("Stop", action: action)
                    .accessibilityIdentifier("stop-button")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// The line under the state pill of the hero.
enum HeroCopy {
    /// paddock's reason of an error or a block. The other states say all
    /// with their word.
    static func reason(_ presentation: StatusPresentation) -> UIText? {
        guard presentation.kind == .error || presentation.kind == .blocked else { return nil }
        return presentation.text.english.isEmpty ? nil : presentation.text
    }
}

/// `.borderedProminent` for the one primary session button, `.bordered`
/// for the rest.
struct SessionButtonStyle: ViewModifier {
    let primary: Bool

    func body(content: Content) -> some View {
        if primary {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// The instances of an app in its Overview, when it has more than one.
@MainActor
struct InstancesSection: View {
    let app: AppItem
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        let items = store.instances(ofApp: app.instance.app)
        if items.count > 1 {
            Section {
                ForEach(items) { item in
                    let presentation = StatusPresentation.of(item.state, now: Date())
                    HStack {
                        AppStatusView(presentation: presentation)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.title).labelInk()
                            Text(presentation.text).font(.callout).labelInk()
                        }
                        Spacer()
                        if let bytes = item.json.bytes, bytes > 0 {
                            Text(verbatim: Format.gb(bytes)).font(.callout).labelInk().monospacedDigit()
                        }
                        ForEach(SessionButtons.of(item.state, canSuspend: false).filter { $0 != .open }, id: \.self) { button in
                            Button(SessionMenuTitle.of(button)) { SessionCommand.perform(button, item, store: store, router: router) }
                        }
                        if item.key != app.key {
                            Button("Show") { store.selection = .app(item.key) }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("instance-row-" + item.key)
                }
            } header: {
                Text("Instances")
            } footer: {
                Text("Each instance is its own sandbox with its own login, files and rules.")
            }
        }
    }
}

extension AppState {
    var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}
