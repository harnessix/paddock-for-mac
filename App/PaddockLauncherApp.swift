import AppKit
import PaddockKit
import SwiftUI

/// paddock for Mac: one process with a menu bar extra, one main window,
/// the welcome window and the Settings window. SwiftUI views run inside
/// an AppKit lifecycle.
@main
struct PaddockLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(SettingsKey.showInMenuBar, store: LauncherDefaults.store) private var showInMenuBar = true

    private var store: LauncherStore { AppContainer.store }
    private var router: UIRouter { AppContainer.router }
    private var agents: AgentStore { AppContainer.agents }

    var body: some Scene {
        Window("paddock", id: WindowID.main) {
            Group {
                #if DEBUG
                // The probe of the language layout UI test.
                if LayoutProbe.isOn { LayoutProbe() } else { MainWindow() }
                #else
                MainWindow()
                #endif
            }
                .environment(store)
                .environment(agents)
                .environment(router)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 920, height: 620)
        .commands { LauncherCommands(store: store, agents: agents, router: router) }

        Window("Welcome to paddock", id: WindowID.onboarding) {
            OnboardingView()
                .environment(store)
                .environment(agents)
                .environment(router)
                .frame(width: 680, height: 520)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent()
                .environment(store)
                .environment(agents)
                .environment(router)
        } label: {
            MenuBarLabel()
                .environment(store)
                .environment(agents)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(store)
                .environment(agents)
                .frame(minWidth: 640, minHeight: 560)
        }
    }
}

/// The menu bar commands. Every action is also in the window; these are
/// the keyboard paths.
@MainActor
struct LauncherCommands: Commands {
    let store: LauncherStore
    let agents: AgentStore
    let router: UIRouter
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Uninstall…") {
                openWindow(id: WindowID.main)
                router.sheet = .uninstall
            }
        }
        CommandGroup(replacing: .newItem) {
            // ⌘N starts an agent in the Agents section and in an empty
            // window, else adds an app.
            Button("New Agent…") {
                openWindow(id: WindowID.main)
                router.sheet = .newAgent(folder: nil)
            }
            .keyboardShortcut(inAgents ? KeyboardShortcut("n") : nil)
            .disabled(!store.binary.isUsable)
            Button("Add App…") {
                openWindow(id: WindowID.main)
                router.addApp(path: nil, store: store)
            }
            .keyboardShortcut(inAgents ? nil : KeyboardShortcut("n"))
            .disabled(!store.binary.isUsable)
        }
        CommandGroup(after: .sidebar) {
            Button("Apps") {
                store.selection = store.apps.first.map { .app($0.key) }
            }
            .keyboardShortcut("1")
            Button("Questions") { store.selection = .questions }
                .keyboardShortcut("2")
            Button("Base image") { store.selection = .baseImage }
                .keyboardShortcut("3")
            Divider()
            // The same choice as the List / Rooms switch of the toolbar.
            Button("Show as List") { router.setLibraryLayout(.list) }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Show as Rooms") { router.setLibraryLayout(.rooms) }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Divider()
            Button("Refresh") {
                Task {
                    await store.refresh()
                    await agents.refreshRuns(force: true)
                }
            }
                .keyboardShortcut("r")
                .disabled(!store.binary.isUsable)
        }
        CommandMenu("Agent") {
            Button("Stop Agent…") {
                if let room = selectedAgent, room.canStop { router.sheet = .confirmStopAgent(room.key) }
            }
            .keyboardShortcut(".")
            .disabled(selectedAgent?.canStop != true)
            Button("Open in Terminal") {
                if let id = selectedAgent?.runID { TerminalHandoffAction.open(runID: id) }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(selectedAgent?.runID == nil || selectedAgent?.state.isLive != true)
        }
        CommandMenu("App") {
            Button(startStopTitle) { Task { await store.toggleSelected() } }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store.selectedApp == nil)
            Button("Show Log") { store.detailTab = .log }
                .keyboardShortcut("l")
                .disabled(store.selectedApp == nil)
        }
    }

    /// The Agents section, or a window with nothing in it yet: there the
    /// agent comes first.
    private var inAgents: Bool {
        store.selection?.isAgents == true || (store.selection == nil && store.apps.isEmpty)
    }

    private var selectedAgent: AgentRoom? {
        if case .agent(let key)? = store.selection { return agents.room(key) }
        return nil
    }

    private var startStopTitle: LocalizedStringKey {
        store.selectedApp?.state.canStop == true ? "Stop" : "Start" // localized
    }
}

/// The status item icon. A template image: monochrome, the system tints it.
@MainActor
struct MenuBarLabel: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: MenuModel.of(store, keepRunning: LauncherDefaults.keepRunning,
                                                           agents: agents.rooms).iconState))
            .accessibilityLabel(Text("paddock"))
            .onAppear { AppContainer.openWindow = openWindow }
    }
}

enum MenuBarIcon {
    static func symbol(for state: MenuModel.IconState) -> String {
        switch state {
        case .idle: return "shippingbox"
        case .running: return "shippingbox.fill"
        case .question: return "exclamationmark.shield.fill"
        }
    }

    static func image(for state: MenuModel.IconState) -> NSImage {
        let image = NSImage(systemSymbolName: symbol(for: state), accessibilityDescription: "paddock") ?? NSImage()
        image.isTemplate = true
        return image
    }
}
