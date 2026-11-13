#if DEBUG
import AppKit
import PaddockKit
import QuartzCore
import SwiftUI

/// Debug builds only: PADDOCK_LAUNCHER_SNAPSHOT=DIR draws every window to
/// DIR/N-TITLE.png after a few seconds and quits. No screen permission:
/// each window draws its own layer tree into a bitmap.
///
/// - PADDOCK_LAUNCHER_SNAPSHOT_DELAY=SECONDS: the wait before the dump (5).
/// - PADDOCK_LAUNCHER_SNAPSHOT_SELECT=NAME: selects the app with this name,
///   instance key or title, or `Questions`, in the main window first.
/// - PADDOCK_LAUNCHER_SNAPSHOT_ROOMS=1: shows the Rooms view of the
///   library first. The saved List / Rooms choice stays as it was.
/// - PADDOCK_LAUNCHER_SNAPSHOT_SELECT=Agents selects the Agents section,
///   `agent:KEY` one agent room.
/// - PADDOCK_LAUNCHER_SNAPSHOT_SHEET=new-agent opens the New Agent sheet.
/// - PADDOCK_LAUNCHER_SNAPSHOT_WELCOME=N shows step N of the welcome
///   window (1 Welcome, 2 Check this Mac, 3 Start your first agent),
///   whether or not the welcome already ended on this Mac.
/// - PADDOCK_LAUNCHER_SNAPSHOT_MOTION=NAME@MS freezes the motion NAME at
///   MS milliseconds after its start: every room of every window draws
///   that moment of the motion, and a window "Motion NAME@MS" shows it
///   large, with the device cable and a card. `request-out@250` is the
///   character half way to the door. The names are those of
///   `WorldMotion`: request-out, request-back, network, flag-up, box-hop,
///   freeze, thaw, climb, notebook, spark, device-card, spawn, envelope,
///   glow, apply, zoom, loft-pan, card-enter, card-leave, hover,
///   light-on, light-off, wake. With Reduce Motion on, the frame is the
///   cross-fade at that moment.
@MainActor
enum SnapshotDump {
    static func scheduleIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["PADDOCK_LAUNCHER_SNAPSHOT"] else { return }
        let delay = Double(env["PADDOCK_LAUNCHER_SNAPSHOT_DELAY"] ?? "5") ?? 5
        let select = env["PADDOCK_LAUNCHER_SNAPSHOT_SELECT"].flatMap { $0.isEmpty ? nil : $0 }
        let rooms = showsRooms(env)
        let sheet = env["PADDOCK_LAUNCHER_SNAPSHOT_SHEET"]
        let welcome = welcomeStep(env)
        let motion = motionFreeze(env)
        if let asked = env[MotionFreezeSetting.variable], motion == nil {
            let names = MotionFreeze.names.joined(separator: ", ")
            FileHandle.standardError.write(Data("snapshot: no motion \"\(asked)\"; write NAME@MS with one of: \(names)\n".utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                if rooms {
                    // Not setLibraryLayout: a snapshot does not change the saved choice.
                    AppContainer.router.libraryLayout = .rooms
                    AppContainer.showMain(nil)
                    await wait(seconds: 1)
                }
                if let select {
                    self.select(select)
                    // The detail view loads after the selection changes.
                    await wait(seconds: 1)
                }
                if let welcome {
                    AppContainer.router.welcomeStep = welcome.rawValue
                    AppContainer.open(WindowID.onboarding)
                    // Step 2 reads the agents, step 3 the form.
                    await wait(seconds: 2)
                }
                if sheet == "new-agent" {
                    AppContainer.showMain(nil)
                    AppContainer.router.sheet = .newAgent(folder: nil)
                    await wait(seconds: 1)
                }
                if let motion {
                    showMotionGallery(motion)
                    await wait(seconds: 1)
                }
                await dump(to: URL(fileURLWithPath: dir))
                NSApp.terminate(nil)
            }
        }
    }

    /// Selects the sidebar item NAME, as a click on it would.
    private static func select(_ name: String) {
        let apps = AppContainer.store.apps.map { Row(key: $0.key, name: $0.name, title: $0.title) }
        guard let item = sidebarItem(for: name, apps: apps) else {
            let names = (["Questions"] + apps.map(\.key)).joined(separator: ", ")
            FileHandle.standardError.write(Data("snapshot: no sidebar item \"\(name)\"; there are: \(names)\n".utf8))
            return
        }
        AppContainer.showMain(item)
    }

    /// PADDOCK_LAUNCHER_SNAPSHOT_ROOMS: `1` (or `true`, `yes`) opens the Rooms view.
    static func showsRooms(_ env: [String: String]) -> Bool {
        guard let value = env["PADDOCK_LAUNCHER_SNAPSHOT_ROOMS"]?.lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    /// PADDOCK_LAUNCHER_SNAPSHOT_WELCOME: the step with that number, or nil
    /// when the variable is not set or is no number.
    static func welcomeStep(_ env: [String: String]) -> WelcomeStep? {
        guard let value = env["PADDOCK_LAUNCHER_SNAPSHOT_WELCOME"], let number = Int(value) else { return nil }
        return WelcomeStep(rawValue: number)
    }

    /// PADDOCK_LAUNCHER_SNAPSHOT_MOTION: the motion and the moment, or nil
    /// when the variable is not set or is not NAME@MS.
    static func motionFreeze(_ env: [String: String]) -> MotionFreeze? {
        MotionFreeze.parse(env[MotionFreezeSetting.variable])
    }

    /// The window of the motion gallery; it lives until the app quits.
    private static var gallery: NSWindow?

    /// Opens a window with the frozen motion drawn large.
    private static func showMotionGallery(_ freeze: MotionFreeze) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Motion \(freeze.motion.rawValue)@\(freeze.milliseconds)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MotionGallery(freeze: freeze))
        window.center()
        window.makeKeyAndOrderFront(nil)
        gallery = window
    }

    struct Row: Equatable {
        var key: String
        var name: String
        var title: String
    }

    /// The sidebar item of NAME: `Questions` in any case, else an app by
    /// instance key, then name or title, then the same without case.
    static func sidebarItem(for name: String, apps: [Row]) -> SidebarItem? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let lower = wanted.lowercased()
        if lower == "questions" { return .questions }
        if lower == "agents" { return .agents }
        if lower.hasPrefix("agent:") { return .agent(String(wanted.dropFirst("agent:".count))) }
        let app = apps.first { $0.key == wanted }
            ?? apps.first { $0.name == wanted || $0.title == wanted }
            ?? apps.first { $0.key.lowercased() == lower || $0.name.lowercased() == lower || $0.title.lowercased() == lower }
        return app.map { .app($0.key) }
    }

    private static func dump(to dir: URL) async {
        NSApp.activate()
        let windows = NSApp.windows.filter(\.isVisible)
        for (n, window) in windows.enumerated() {
            // A window that is not key draws its controls inactive: gray
            // prominent buttons, a dim sidebar selection.
            if window.canBecomeKey { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
            await wait(seconds: 0.3)
            window.displayIfNeeded()
            CATransaction.flush()
            await nextPass()
            guard let data = png(of: window) else {
                FileHandle.standardError.write(Data("snapshot: could not draw \"\(window.title)\"\n".utf8))
                continue
            }
            let name = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "-")
            try? data.write(to: dir.appendingPathComponent("\(n)-\(name).png"))
        }
    }

    /// The window frame view (title bar included) drawn through its layer
    /// tree. `cacheDisplay` misses layer-hosted content such as the
    /// sidebar `List`; `render(in:)` draws what Core Animation holds.
    private static func png(of window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        guard let layer = view.layer else { return cachedPNG(of: view) }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return cachedPNG(of: view) }
        // Materials (the sidebar) blur what is behind the window, which a
        // layer render cannot see: start from the window background.
        var background = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // render(in:) applies the flips of the tree itself, as on screen.
        layer.render(in: context)
        guard let image = context.makeImage() else { return cachedPNG(of: view) }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    /// The old path, for a view without a layer.
    private static func cachedPNG(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// One pass of the main run loop: layout, display and the Core
    /// Animation commit run before the next main-queue block.
    private static func nextPass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func wait(seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}
#endif
