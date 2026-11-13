import AppKit
import PaddockKit
import SwiftUI

/// One room with the motion of the world: the state goes in, the motion
/// comes out. `scene` is the room, the character and its pose; `world` is
/// what paddock does in the room (a request, the network, mail, frost,
/// the loft, a child run, the copy). When the world changes, the room
/// moves from the picture before to the new one, and then it rests.
///
/// The room draws the layers of `RoomView` and, between them, the small
/// parts of `WorldArt`. A part that is not there costs nothing: a room
/// with a plain world has no canvas at all. The whole room only
/// decorates: the text next to it says the same, so VoiceOver skips it.
///
/// A page places a room with `StagedRoom`, which hosts this view.
@MainActor
struct RoomSceneView: View {
    let scene: RoomScene
    let icon: RoomIcon
    let side: CGFloat
    /// Nil: the world of the scene alone (`RoomWorld.of(scene)`).
    var world: RoomWorld?
    /// True: the room comes on screen dark, then the light turns on.
    var entrance = false
    @State private var onScreen = false
    /// The art this room holds while it is on screen.
    @State private var held: [RoomArtKey] = []

    /// How dark a room without light is: the part of ink over it.
    static let darkness = 0.34

    var body: some View {
        MotionHost(world: world ?? RoomWorld.of(scene), pose: scene.pose, entrance: entrance) { moment in
            picture(moment)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .topTrailing) { progress }
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
        .onChange(of: scene) { _, new in
            if onScreen { hold(RoomArtLoader.keys(new)) }
        }
    }

    /// Holds `keys` in place of the art held before.
    private func hold(_ keys: [RoomArtKey]) {
        guard keys != held else { return }
        let art = RoomArtLoader.shared
        art.hold(keys)
        art.release(held)
        held = keys
    }

    // MARK: The picture of a moment

    /// The frame of the moment. With Reduce Motion the frame before is
    /// under it while the two cross-fade.
    private func picture(_ moment: MotionMoment) -> some View {
        ZStack(alignment: .topLeading) {
            if let previous = moment.snapshot.previous {
                room(previous, moment)
            }
            room(moment.snapshot.frame, moment)
                .opacity(moment.snapshot.previous == nil ? 1 : moment.snapshot.fade)
        }
    }

    /// The room and the loft over it, moved down by the pan.
    private func room(_ frame: RoomMotionFrame, _ moment: MotionMoment) -> some View {
        let art = RoomArtLoader.shared
        let manifest = art.manifest
        let box = IconPlacement.characterBox(manifest, tint: scene.tint, side: Double(side))
        // Points for one pixel of the room art.
        let unit = side / CGFloat(RoomPlaces.size)
        let offset = RoomPlaces.characterOffset(frame)
        let origin = CGPoint(x: CGFloat(box.x) + CGFloat(offset.x) * unit, y: CGFloat(box.y) + CGFloat(offset.y) * unit)
        let size = CGFloat(box.size)
        let walls = SpriteFrameView(frame: art.room(scene.tint), manifest: manifest)
            .frame(width: side, height: side)
        return ZStack(alignment: .topLeading) {
            walls
            if WorldBackCanvas.draws(frame) {
                WorldBackCanvas(frame: frame, tint: scene.tint)
                    .frame(width: side, height: frame.hasLoft ? 2 * side : side)
                    .offset(y: frame.hasLoft ? -side : 0)
            }
            character(frame, moment, size: size)
                .offset(x: origin.x, y: origin.y)
            SpriteFrameView(frame: art.front(), manifest: manifest)
                .frame(width: side, height: side)
            iconView
                .frame(width: RoomView.iconSide, height: RoomView.iconSide)
                .projectionEffect(RoomView.projection(manifest, tint: scene.tint, side: side))
            if WorldFrontCanvas.draws(frame) {
                WorldFrontCanvas(frame: frame, tint: scene.tint,
                                 character: CGPoint(x: origin.x / unit, y: origin.y / unit), characterSize: size / unit,
                                 breath: moment.playing ? RoomMotionFrame.breath(at: moment.date) : 1)
                    .frame(width: side, height: side)
            }
            if frame.light < 0.999 {
                // The light is off: the room is darker, in its own shape.
                WorldArt.ink
                    .opacity(RoomSceneView.darkness * (1 - frame.light))
                    .frame(width: side, height: side)
                    .mask { walls }
            }
            if frame.frost > 0.01 {
                FrostCanvas(amount: frame.frost)
                    .frame(width: side, height: side)
                    .mask { walls }
            }
            if let badge = scene.badge, badge > 0, frame.pose == .wait {
                // On the corner of the "!" bubble of the wait loop.
                QuestionBadge(count: badge, side: side)
                    .offset(x: origin.x + size * 0.82, y: origin.y + size * 0.06)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .offset(y: CGFloat(frame.pan) * side)
    }

    /// The character: the loop of the frame, and under it the loop it
    /// leaves while the two cross-fade.
    private func character(_ frame: RoomMotionFrame, _ moment: MotionMoment, size: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let from = frame.fromPose {
                // The old loop stays whole for the first half, so the
                // room never shows through the character.
                sprite(from, frame, moment, size: size)
                    .opacity(min(1, 2 * (1 - frame.poseBlend)))
            }
            sprite(frame.pose, frame, moment, size: size)
                .opacity(frame.fromPose == nil ? 1 : frame.poseBlend)
        }
    }

    private func sprite(_ pose: CharacterPose, _ frame: RoomMotionFrame, _ moment: MotionMoment, size: CGFloat) -> some View {
        let art = RoomArtLoader.shared
        let frames = art.character(scene.color, pose.roomSprite)
        let player = SpritePlayer(frameCount: frames.count, start: moment.spriteStart)
        // A frozen character holds the frame it had.
        let index = frame.heldAt.map { player.frame(at: $0, playing: true) }
            ?? player.frame(at: moment.date, playing: moment.playing)
        let box = IconPlacement.characterBox(art.manifest, tint: scene.tint, side: Double(side))
        // At the desk the laptop of the work loop would show under the
        // desk. In the loft the whole loop shows.
        let shown = frame.climb > 0 ? size
            : RoomView.characterHeight(pose, box: box, side: side, placeholder: frames[0].isPlaceholder)
        return SpriteFrameView(frame: frames[index % frames.count], manifest: art.manifest)
            .frame(width: size, height: size)
            .frame(height: shown, alignment: .top)
            .clipped()
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

    @ViewBuilder private var progress: some View {
        if scene.showsProgress {
            ProgressView()
                .controlSize(side < 150 ? .mini : .small)
                .padding(Space.s)
                .background(.regularMaterial, in: Circle())
                .padding(side * 0.03)
        }
    }
}
