import AppKit
import PaddockKit
import SwiftUI

/// The menu of the status item: a control surface for the agents and the
/// apps that run. The agents come first: how many run, each with its
/// state, their requests and New Agent. The apps follow with the base
/// image line, but only once there is an app or a base image. The window
/// is for setup.
@MainActor
struct MenuBarContent: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(UIRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.keepRunning, store: LauncherDefaults.store) private var keepRunning = true

    var body: some View {
        let menu = MenuModel.of(store, keepRunning: keepRunning, agents: agents.rooms)
        Text(menu.agentsHeader)
        ForEach(menu.agents) { item in
            agentMenu(item)
        }
        if let requests = menu.agentRequestsItem {
            Button { showMain(.questions) } label: { Text(requests) }
        }
        Button("New Agent…") {
            router.sheet = .newAgent(folder: nil)
            showMain(nil)
        }
        .disabled(!store.binary.isUsable)
        Divider()
        if menu.showsApps {
            Text(menu.header)
            ForEach(menu.apps) { app in
                appMenu(app)
            }
            if menu.showsMore {
                Button("More…") { showMain(nil) }
            }
        }
        if let questions = menu.questionsItem {
            Button { showMain(.questions) } label: { Text(questions) }
        }
        if menu.showsApps || menu.questionsItem != nil {
            Divider()
        }
        Button("Open paddock") { showMain(nil) }
            .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit paddock for Mac") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
        if let note = menu.quitNote {
            Text(note)
        }
    }

    /// One app: its 16 pt icon with the state dot, the name, and a submenu
    /// that starts with the state line, then the session actions.
    private func appMenu(_ app: AppItem) -> some View {
        let presentation = StatusPresentation.of(app.state, now: Date())
        return Menu {
            Text(presentation.text)
            Divider()
            ForEach(SessionButtons.of(app.state, canSuspend: store.capabilities.suspend), id: \.self) { button in
                Button(SessionMenuTitle.of(button)) {
                    SessionCommand.perform(button, app, store: store, router: router)
                    if button == .stop, router.sheet != nil { showMain(.app(app.key)) }
                }
            }
            Button("Open New Instance") { SessionCommand.newInstance(app, store: store) }
                .disabled(app.state.isBlocked)
            Divider()
            Button("Grants…") {
                store.detailTab = .grants
                showMain(.app(app.key))
            }
            Button("Show Log") {
                store.detailTab = .log
                showMain(.app(app.key))
            }
        } label: {
            Label {
                Text(verbatim: app.title)
            } icon: {
                Image(nsImage: MenuAppIcon.image(path: app.json.bundlePath, presentation: presentation))
            }
            .accessibilityLabel(Text(verbatim: app.title + ", " + presentation.accessibilityLabel.localized))
        } primaryAction: {
            if app.state.isRunning, SessionActivator.activate(app) { return }
            Task { await store.primaryAction(app.key) }
        }
    }

    /// One running agent: its character, `Claude Code in shop — Working`,
    /// and a submenu with Open, Open in Terminal and Stop….
    private func agentMenu(_ item: AgentMenuItem) -> some View {
        let room = agents.room(item.key)
        return Menu {
            Text(item.state.line)
            Divider()
            Button("Open") { showMain(.agent(item.key)) }
            if let id = room?.runID {
                Button("Open in Terminal") { TerminalHandoffAction.open(runID: id) }
            }
            if room?.canStop == true {
                Button("Stop…") {
                    showMain(.agent(item.key))
                    router.sheet = .confirmStopAgent(item.key)
                }
            }
        } label: {
            Label {
                Text(item.line)
            } icon: {
                Image(nsImage: MenuAgentIcon.image(room?.color ?? .gray, state: item.state))
            }
            .accessibilityLabel(Text(item.line))
        } primaryAction: {
            showMain(.agent(item.key))
        }
    }

    private func showMain(_ selection: SidebarItem?) {
        if let selection { store.selection = selection }
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

/// The 16 pt icon of an app in the menu: the bundle icon with the state as
/// a dot on its lower right corner, as OrbStack marks its machines. A
/// missing bundle draws the generic app icon at half strength.
@MainActor
enum MenuAppIcon {
    static func dotColor(_ presentation: StatusPresentation) -> NSColor {
        switch presentation.kind {
        case .running: return .systemGreen
        case .error: return .systemOrange
        case .blocked: return .systemRed
        default: return .systemGray
        }
    }

    static func image(path: String?, presentation: StatusPresentation) -> NSImage {
        let found = path.flatMap { AppIconCache.icon($0) }
        let base = found ?? AppIconCache.generic
        let strength: CGFloat = found == nil ? 0.5 : 1
        let dot = dotColor(presentation)
        let side = IconSize.menu
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: strength)
            let spot = NSRect(x: rect.maxX - 6, y: rect.minY, width: 6, height: 6)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: spot.insetBy(dx: -1, dy: -1)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: spot).fill()
            return true
        }
        image.accessibilityDescription = presentation.accessibilityLabel.localized
        return image
    }
}

/// The 16 pt mark of an agent in the menu: a dot in the color of its
/// character, with a red ring while it waits for you.
@MainActor
enum MenuAgentIcon {
    static func image(_ color: CharacterColor, state: AgentState) -> NSImage {
        let side = IconSize.menu
        let fill = NSColor(RoomPalette.character(color))
        let waiting: Bool
        if case .waiting = state { waiting = true } else { waiting = false }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let dot = rect.insetBy(dx: 2, dy: 2)
            fill.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if waiting {
                NSColor.systemRed.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                ring.stroke()
            }
            return true
        }
        image.accessibilityDescription = state.word.localized
        return image
    }
}
