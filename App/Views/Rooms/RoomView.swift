import AppKit
import PaddockKit
import SwiftUI

/// The icon on the laptop screen of a room: an app bundle's own icon, or
/// an image such as paddock's icon in the onboarding.
enum RoomIcon {
    case app(path: String?)
    case image(NSImage)
}

/// One room, drawn in the order of `RoomLayer.drawOrder`: the room, the
/// character in the pose of the state, the front layer (the desk and the
/// laptop, so the character sits behind them), the real app icon on the
/// laptop screen, the question badge and the start spinner. The whole
/// room is decorative: the card or the header next to it says the same in
/// text, so VoiceOver skips it.
///
/// The character loops at 8 fps only while the window is visible and the
/// room is on screen; with Reduce Motion it shows its first frame. A
/// running app with a window plays the work loop behind its desk. A loop
/// that does not play has no timeline at all: no timer runs for it. All
/// loops tick on one grid (`SpritePlayer.aligned`), so every room on
/// screen changes its frame in the same display frame. A room holds its
/// art only while it is on screen.
@MainActor
struct RoomView: View {
    let scene: RoomScene
    let icon: RoomIcon
    let side: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.roomWindowVisible) private var windowVisible
    @State private var onScreen = false
    /// The start of the loop, on the shared tick.
    @State private var start = SpritePlayer.aligned(Date())
    /// The art this room holds while it is on screen.
    @State private var held: [RoomArtKey] = []

    /// The icon view is drawn at the old header size, then mapped onto
    /// the laptop screen.
    static let iconSide: CGFloat = IconSize.header

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(RoomLayer.drawOrder, id: \.self) { layer in
                self.layer(layer)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            onScreen = true
            hold(RoomArtLoader.keys(scene))
        }
        .onDisappear {
            onScreen = false
            hold([])
        }
        // A new pose starts its loop at the first frame.
        .onChange(of: scene.pose) { start = SpritePlayer.aligned(Date()) }
        .onChange(of: scene) { if onScreen { hold(RoomArtLoader.keys(scene)) } }
    }

    /// Holds `keys` in place of the art held before.
    private func hold(_ keys: [RoomArtKey]) {
        guard keys != held else { return }
        let art = RoomArtLoader.shared
        art.hold(keys)
        art.release(held)
        held = keys
    }

    @ViewBuilder private func layer(_ layer: RoomLayer) -> some View {
        let art = RoomArtLoader.shared
        let manifest = art.manifest
        switch layer {
        case .room:
            SpriteFrameView(frame: art.room(scene.tint), manifest: manifest)
                .frame(width: side, height: side)
        case .character:
            let frames = art.character(scene.color, scene.pose.roomSprite)
            let playing = SpritePlayer.isPlaying(windowVisible: windowVisible, onScreen: onScreen,
                                                 reduceMotion: reduceMotion, frameCount: frames.count)
            let box = characterBox
            Group {
                if playing {
                    let player = SpritePlayer(frameCount: frames.count, start: start)
                    // A periodic timeline from the aligned start: its
                    // ticks are the ticks of every other room.
                    TimelineView(.periodic(from: start, by: SpritePlayer.frameInterval)) { context in
                        SpriteFrameView(frame: frames[player.frame(at: context.date, playing: true) % frames.count],
                                        manifest: manifest)
                    }
                } else {
                    SpriteFrameView(frame: frames[0], manifest: manifest)
                }
            }
            .frame(width: CGFloat(box.size), height: CGFloat(box.size))
            // The laptop of the work loop would show under the desk.
            .frame(height: RoomView.characterHeight(scene.pose, box: box, side: side, placeholder: frames[0].isPlaceholder),
                   alignment: .top)
            .clipped()
            .offset(x: CGFloat(box.x), y: CGFloat(box.y))
        case .front:
            SpriteFrameView(frame: art.front(), manifest: manifest)
                .frame(width: side, height: side)
        case .icon:
            iconView
                .frame(width: RoomView.iconSide, height: RoomView.iconSide)
                .projectionEffect(RoomView.projection(manifest, tint: scene.tint, side: side))
        case .badge:
            if let badge = scene.badge, badge > 0 {
                let box = characterBox
                // On the corner of the "!" bubble of the wait loop.
                QuestionBadge(count: badge, side: side)
                    .offset(x: CGFloat(box.x + box.size * 0.82), y: CGFloat(box.y + box.size * 0.06))
            }
        case .progress:
            if scene.showsProgress {
                ProgressView()
                    .controlSize(side < 150 ? .mini : .small)
                    .padding(Space.s)
                    .background(.regularMaterial, in: Circle())
                    .padding(side * 0.03)
                    .frame(width: side, height: side, alignment: .topTrailing)
            }
        }
    }

    /// The height of the character layer that shows: all of it, but the
    /// work loop of the art ends at the underside of the desk.
    static func characterHeight(_ pose: CharacterPose, box: CharacterBox, side: CGFloat, placeholder: Bool) -> CGFloat {
        let full = CGFloat(box.size)
        guard pose.roomSprite == .work, !placeholder else { return full }
        let floor = side * CGFloat(CharacterArt.workFloor) - CGFloat(box.y)
        return min(full, max(0, floor))
    }

    private var characterBox: CharacterBox {
        IconPlacement.characterBox(RoomArtLoader.shared.manifest, tint: scene.tint, side: Double(side))
    }

    @ViewBuilder private var iconView: some View {
        switch icon {
        case .app(let path):
            AppIcon(path: path, size: RoomView.iconSide)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        }
    }

    /// The projective map of the icon view onto its place on the laptop
    /// screen. SwiftUI multiplies row vectors: x' = (m11 x + m21 y + m31) / w.
    static func projection(_ manifest: RoomsManifest, tint: RoomTint, side: CGFloat) -> ProjectionTransform {
        let map = IconPlacement.transform(manifest, tint: tint, side: Double(side), iconSide: Double(iconSide))
        var transform = ProjectionTransform()
        transform.m11 = CGFloat(map.a)
        transform.m21 = CGFloat(map.b)
        transform.m31 = CGFloat(map.c)
        transform.m12 = CGFloat(map.d)
        transform.m22 = CGFloat(map.e)
        transform.m32 = CGFloat(map.f)
        transform.m13 = CGFloat(map.g)
        transform.m23 = CGFloat(map.h)
        transform.m33 = 1
        return transform
    }
}

/// One sprite frame: the PNG, or its placeholder.
@MainActor
struct SpriteFrameView: View {
    let frame: SpriteFrame
    let manifest: RoomsManifest

    var body: some View {
        switch frame {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        case .placeholderCharacter(let color, let pose, let index):
            PlaceholderCharacter(color: color, pose: pose, frame: index)
        case .placeholderRoom(let tint):
            PlaceholderRoom(tint: tint, manifest: manifest)
        case .placeholderFront:
            Color.clear
        }
    }
}

/// The question count on a waiting character: white on red, as the
/// badges of the Dock.
@MainActor
struct QuestionBadge: View {
    let count: Int
    let side: CGFloat

    var body: some View {
        let height = max(14, side * 0.12)
        Text(verbatim: String(count))
            .font(.system(size: height * 0.62, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height)
            .background(Capsule().fill(Color(nsColor: .systemRed)))
            .overlay(Capsule().strokeBorder(Color.white, lineWidth: max(1, height * 0.08)))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

// MARK: - Window visibility

private struct RoomWindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the window of the view is hidden, covered or in the
    /// Dock: the room loops stop.
    var roomWindowVisible: Bool {
        get { self[RoomWindowVisibleKey.self] }
        set { self[RoomWindowVisibleKey.self] = newValue }
    }
}

extension View {
    /// Tells the rooms under this view whether their window is visible.
    func tracksWindowVisibility() -> some View {
        modifier(WindowVisibilityModifier())
    }
}

private struct WindowVisibilityModifier: ViewModifier {
    @State private var visible = true

    func body(content: Content) -> some View {
        content
            .environment(\.roomWindowVisible, visible)
            .background(
                WindowVisibilityReader(visible: $visible)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true))
    }
}

/// Watches the occlusion state of the window that holds it.
private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = { value in if visible != value { visible = value } }
        return view
    }

    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.onChange = { value in if visible != value { visible = value } }
    }
}

final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
        if let window {
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification]
            for name in names {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.report()
                    }
                })
            }
        }
        report()
    }

    /// Reports after the current update: SwiftUI state must not change
    /// while it lays out.
    private func report() {
        let visible = isWindowVisible
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange?(visible)
            }
        }
    }

    /// True when the window of this view is visible now.
    var isWindowVisible: Bool {
        window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
    }
}
