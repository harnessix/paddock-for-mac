import AppKit
import PaddockKit
import SwiftUI
import UserNotifications

/// The AppKit side: launch, quit, app-level alerts and notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var notified: Set<String> = []
    private var agentNotifier = AgentNotifier()
    private var notifyTimer: Timer?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SnapshotDump.scheduleIfAsked()
        #endif
        if !AppContainer.isUITest {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
        }
        // The notices of the event stream: paddock for Mac shows each one
        // itself, with its icon.
        AppContainer.store.onNotice = { NoticePoster.post($0) }
        Task {
            await AppContainer.start()
            showVersionAlertIfNeeded()
        }
        // A local check of the questions already loaded; it never calls paddock.
        notifyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.notifyWaitingQuestions()
                self?.notifyAgents()
            }
        }
    }

    /// An app dropped on the Dock icon, or opened with paddock for Mac from
    /// Finder: the same review sheet as a drop on the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        Task {
            await AppContainer.start()
            guard AppContainer.store.binary.isUsable else {
                AppContainer.showMain(nil)
                return
            }
            // A project folder on the Dock icon starts an agent there.
            if let folder = AgentForm.droppedFolder(paths, isFolder: NewAgentSheet.isFolder) {
                AppContainer.showMain(.agents)
                AppContainer.router.sheet = .newAgent(folder: folder)
                return
            }
            AddCenter.shared.receive(paths)
        }
    }

    /// Closing the window keeps the menu bar item and running apps.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting the launcher keeps apps running unless the setting is off;
    /// a running build is paused.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The agents of the terminal panes are children of the launcher:
        // they stop with it. Ask first.
        let panes = AppContainer.agents.panes.filter(\.running).count
        if panes > 0, !quitting, !AppContainer.isUITest {
            let alert = AppAlert.make()
            alert.messageText = AgentQuitCopy.question(panes).localized
            alert.informativeText = AgentQuitCopy.detail.localized
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        let store = AppContainer.store
        let keep = LauncherDefaults.keepRunning
        let plan = QuitPlanner.plan(keepRunning: keep, apps: store.apps, building: store.isBuilding)
        guard !plan.isEmpty, !quitting else { return .terminateNow }
        quitting = true
        Task {
            await store.performQuit(keepRunning: keep)
            store.stopEvents()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The app-level alert for a paddock of the wrong version. A missing
    /// paddock shows in the onboarding window instead.
    private func showVersionAlertIfNeeded() {
        guard case .found(_, let verdict) = AppContainer.store.binary,
              let error = VersionGate.current.error(for: verdict), error != .notInstalled else { return }
        let alert = AppAlert.make()
        alert.messageText = error.title?.localized ?? ""
        alert.informativeText = error.body?.localized ?? ""
        // A paddock that did not answer has no command to copy.
        let command = error.command
        if command != nil { alert.addButton(withTitle: LauncherError.Primary.copyCommand.title!.localized) }
        alert.addButton(withTitle: String(localized: "Check Again"))
        alert.addButton(withTitle: String(localized: "Quit"))
        // The index of the button in the full list: Copy, Check Again, Quit.
        let order: [NSApplication.ModalResponse] = [.alertFirstButtonReturn, .alertSecondButtonReturn,
                                                     .alertThirdButtonReturn]
        let shown = order.firstIndex(of: alert.runModal()) ?? order.count
        switch shown + (command == nil ? 1 : 0) {
        case 0:
            if let command { Pasteboard.copy(command) }
            showVersionAlertIfNeeded()
        case 1:
            Task {
                await AppContainer.checkAgain()
                showVersionAlertIfNeeded()
            }
        default:
            NSApp.terminate(nil)
        }
    }

    // MARK: Notifications

    /// Every notification of paddock for Mac goes through `NoticePoster`:
    /// the notices of the event stream come from the store (`onNotice`),
    /// the questions and the agent rooms from this timer.
    private func notifyWaitingQuestions() {
        let store = AppContainer.store
        let due = QuestionNotifier.due(store.questions, now: Date(), threshold: LauncherDefaults.notifyAfter,
                                       notified: notified)
        for question in due {
            notified.insert(question.id)
            store.post(Notice(question: question))
        }
    }

    /// An agent waits for you or ended: one notification each, with the
    /// setting of the app questions ("Never" turns them off too).
    private func notifyAgents() {
        let notices = agentNotifier.update(AppContainer.agents.rooms, now: Date(), threshold: LauncherDefaults.notifyAfter)
        for notice in notices {
            AppContainer.store.post(Notice(agent: notice))
        }
    }

    /// The app is in front: the notice of the window line shows there, so
    /// the system only lists it. Every other notice shows its banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let inWindow = notification.request.content.userInfo[NoticePoster.windowKey] as? String == "1"
        Task { @MainActor in
            completionHandler(NoticePoster.presentation(inWindow: inWindow, windowVisible: NoticePoster.mainWindowVisible))
        }
    }

    /// A click on a notification: the main window, on the place the
    /// notice is about. The notification of a waiting request opens the
    /// Questions list on its card.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        var info: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        Task { @MainActor in
            NoticeOpener.open(userInfo: info)
            completionHandler()
        }
    }
}

/// Posts the notices as notifications of paddock for Mac. The system
/// shows them with the icon of the app. Nothing here runs `osascript`,
/// and nothing else in the launcher posts a notification.
@MainActor
enum NoticePoster {
    /// `1` in the `userInfo` of a notice that the window also shows.
    nonisolated static let windowKey = "window"
    /// The last notices handed over, the newest last. A UI test has no
    /// Notification Center: there the notices only come here.
    private(set) static var posted: [Notice] = []

    static func post(_ notice: Notice) {
        posted.append(notice)
        if posted.count > 50 { posted.removeFirst(posted.count - 50) }
        guard !AppContainer.isUITest else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.add(UNNotificationRequest(identifier: notice.id, content: content(notice), trigger: nil))
    }

    /// The title and the text in the language of the app, and where a
    /// click goes.
    static func content(_ notice: Notice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title.localized
        content.body = notice.body.localized
        content.sound = .default
        var info = NoticeRoute.userInfo(notice)
        if notice.showsInWindow { info[windowKey] = "1" }
        content.userInfo = info
        return content
    }

    nonisolated static func presentation(inWindow: Bool, windowVisible: Bool) -> UNNotificationPresentationOptions {
        inWindow && windowVisible ? [.list] : [.banner, .list, .sound]
    }

    /// True while the main window is on screen and paddock for Mac is the
    /// app in front.
    static var mainWindowVisible: Bool {
        NSApp.isActive && NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && (window.identifier?.rawValue.hasPrefix(WindowID.main) ?? false)
        }
    }
}

/// Opens the place a notice is about: from a click on its notification,
/// or from Show in the window.
@MainActor
enum NoticeOpener {
    static func open(_ notice: Notice) {
        AppContainer.store.dismissNotice(notice.id)
        open(target: notice.target, card: notice.card)
    }

    static func open(userInfo: [String: String]) {
        let destination = NoticeRoute.destination(userInfo)
        open(target: destination.target, card: destination.card)
    }

    static func open(target: SidebarItem?, card: String?) {
        let item = resolve(target, store: AppContainer.store, rooms: AppContainer.agents.rooms)
        AppContainer.router.focusCard = card
        if let item {
            // The Rooms layout opens the room, not only its card.
            switch item {
            case .agent, .app: AppContainer.store.openRoom = item
            default: break
            }
        }
        AppContainer.showMain(item)
    }

    /// The sidebar item of a target. A notice of paddock names an agent by
    /// its run; the room may have the key of its pane. An app or a run
    /// that is gone leads to its section, never to an empty detail.
    static func resolve(_ target: SidebarItem?, store: LauncherStore, rooms: [AgentRoom]) -> SidebarItem? {
        switch target {
        case .agent(let key)?:
            if let room = rooms.first(where: { $0.key == key || $0.runID == key }) { return .agent(room.key) }
            return .agents
        case .app(let key)?:
            if store.app(named: key) != nil || !store.listLoaded { return target }
            return store.apps.first.map { .app($0.key) }
        default:
            return target
        }
    }
}
