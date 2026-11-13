import AppKit
import PaddockKit
import SwiftUI
import XCTest
@testable import PaddockLauncher

/// The app side of the motion: the SwiftUI animations of the kit's
/// motions, the lift and the zoom of a card, the schedule of a room, the
/// parts a frame draws, and a picture of every motion at its start, its
/// middle and its end.
@MainActor
final class MotionAppChecks: XCTestCase {
    let start = MotionDemo.start

    // MARK: Animations

    // Each motion has the length and the curve of the kit. With Reduce
    // Motion it is the 150 ms cross-fade. A UI test run has none.
    func testAnimationsFollowTheKit() {
        XCTAssertEqual(WorldMotion.zoom.animation(reduceMotion: false, still: false),
                       Animation.spring(duration: 0.45, bounce: 0.12))
        XCTAssertEqual(WorldMotion.loftPan.animation(reduceMotion: false, still: false), Animation.easeInOut(duration: 0.35))
        XCTAssertEqual(WorldMotion.cardEnter.animation(reduceMotion: false, still: false), Animation.easeOut(duration: 0.22))
        XCTAssertEqual(WorldMotion.cardLeave.animation(reduceMotion: false, still: false), Animation.easeIn(duration: 0.16))
        XCTAssertEqual(WorldMotion.spark.animation(reduceMotion: false, still: false), Animation.linear(duration: 0.4))
        for motion in WorldMotion.allCases {
            XCTAssertNotNil(motion.animation(reduceMotion: false, still: false), motion.rawValue)
            XCTAssertEqual(motion.animation(reduceMotion: true, still: false), Animation.linear(duration: 0.15), motion.rawValue)
            XCTAssertNil(motion.animation(reduceMotion: false, still: true), motion.rawValue)
            XCTAssertNil(motion.animation(reduceMotion: true, still: true), motion.rawValue)
        }
    }

    // The scheme sets PADDOCK_LAUNCHER_UITEST: in a test run no room moves.
    func testTestRunsHaveNoMotion() {
        let mode = RoomMotionMode.of(windowVisible: true, onScreen: true, reduceMotion: false, still: Motion.still)
        XCTAssertEqual(mode, Motion.still ? .none : .full)
        if Motion.still {
            XCTAssertNil(WorldMotion.zoom.animation(reduceMotion: false))
            XCTAssertNil(WorldMotion.hover.animation(reduceMotion: false))
        }
    }

    // MARK: Cards

    // The pointer lifts a card a little. With Reduce Motion it stays.
    func testHoverLift() {
        XCTAssertEqual(HoverLift.lift(hovering: false, reduceMotion: false, freeze: nil).lift, 0)
        XCTAssertEqual(HoverLift.lift(hovering: false, reduceMotion: false, freeze: nil).scale, 1)
        let lifted = HoverLift.lift(hovering: true, reduceMotion: false, freeze: nil)
        XCTAssertEqual(lifted.lift, CardMotion.hoverLift)
        XCTAssertEqual(lifted.scale, CardMotion.hoverScale, accuracy: 1e-12)
        XCTAssertEqual(HoverLift.lift(hovering: true, reduceMotion: true, freeze: nil).lift, 0)
        XCTAssertEqual(HoverLift.lift(hovering: true, reduceMotion: true, freeze: nil).scale, 1)
        // A frozen moment of the hover, whatever the pointer does.
        let half = HoverLift.lift(hovering: false, reduceMotion: false, freeze: MotionFreeze(motion: .hover, milliseconds: 60))
        XCTAssertGreaterThan(half.lift, 0)
        XCTAssertLessThan(half.lift, CardMotion.hoverLift)
        let other = HoverLift.lift(hovering: false, reduceMotion: false, freeze: MotionFreeze(motion: .freeze, milliseconds: 60))
        XCTAssertEqual(other.lift, 0)
    }

    // The frozen moments of a card that comes or goes.
    func testFrozenCardPhases() {
        let plain = FrozenCardMotion.phase(nil, reduceMotion: false)
        XCTAssertEqual(plain.scale, 1)
        XCTAssertEqual(plain.opacity, 1)
        let first = FrozenCardMotion.phase(MotionFreeze(motion: .cardEnter, milliseconds: 0), reduceMotion: false)
        XCTAssertEqual(first.scale, CardMotion.enterScale)
        XCTAssertEqual(first.opacity, 0)
        let last = FrozenCardMotion.phase(MotionFreeze(motion: .cardEnter, milliseconds: 220), reduceMotion: false)
        XCTAssertEqual(last.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(last.opacity, 1)
        let gone = FrozenCardMotion.phase(MotionFreeze(motion: .cardLeave, milliseconds: 160), reduceMotion: false)
        XCTAssertEqual(gone.scale, CardMotion.leaveScale, accuracy: 1e-12)
        XCTAssertEqual(gone.opacity, 0)
        // With Reduce Motion: only the fade, 150 ms.
        let fade = FrozenCardMotion.phase(MotionFreeze(motion: .cardEnter, milliseconds: 75), reduceMotion: true)
        XCTAssertEqual(fade.scale, 1)
        XCTAssertEqual(fade.opacity, 0.5, accuracy: 1e-12)
        let other = FrozenCardMotion.phase(MotionFreeze(motion: .zoom, milliseconds: 75), reduceMotion: false)
        XCTAssertEqual(other.opacity, 1)
    }

    // MARK: The zoom

    // The room of the detail starts at the card and ends at its own
    // place. With Reduce Motion it fades in where it is.
    func testZoomFromTheCard() {
        let card = CGRect(x: 40, y: 300, width: 176, height: 176)
        let own = CGRect(x: 320, y: 60, width: 88, height: 88)
        let first = ZoomEffect.look(progress: 0, origin: card, own: own, reduceMotion: false, plain: false)
        XCTAssertEqual(first.transform.scale, 2)
        XCTAssertEqual(first.transform.x, Double(card.midX - own.midX))
        XCTAssertEqual(first.transform.y, Double(card.midY - own.midY))
        XCTAssertEqual(first.opacity, 0)
        let third = ZoomEffect.look(progress: 1.0 / 3, origin: card, own: own, reduceMotion: false, plain: false)
        XCTAssertEqual(third.opacity, 1, accuracy: 1e-12, "solid after a third of the way")
        let last = ZoomEffect.look(progress: 1, origin: card, own: own, reduceMotion: false, plain: false)
        XCTAssertEqual(last.transform, .identity)
        XCTAssertEqual(last.opacity, 1)

        let reduced = ZoomEffect.look(progress: 0.5, origin: card, own: own, reduceMotion: true, plain: false)
        XCTAssertEqual(reduced.transform, .identity)
        XCTAssertEqual(reduced.opacity, 0.5)

        // No card: the room does not move.
        let none = ZoomEffect.look(progress: 1, origin: nil, own: own, reduceMotion: false, plain: false)
        XCTAssertEqual(none.transform, .identity)
        XCTAssertEqual(none.opacity, 1)
        // A card, but the room does not know its place yet: hidden, not
        // drawn at the end place.
        let early = ZoomEffect.look(progress: 0, origin: card, own: .zero, reduceMotion: false, plain: false)
        XCTAssertEqual(early.transform, .identity)
        XCTAssertEqual(early.opacity, 0)
        // A frozen moment of a snapshot: the room grows in place.
        let frozen = ZoomEffect.look(progress: 0, origin: nil, own: .zero, reduceMotion: false, plain: true)
        XCTAssertEqual(frozen.transform.scale, CardMotion.zoomFallbackScale)
    }

    // The center knows a card while it is on screen and for a moment
    // after it left; then a detail does not zoom from it any more.
    func testZoomCenterForgetsOldCards() {
        let center = RoomZoomCenter()
        let frame = CGRect(x: 10, y: 20, width: 176, height: 176)
        XCTAssertNil(center.origin("notes"))
        center.record("notes", frame: frame)
        XCTAssertEqual(center.origin("notes", at: start.addingTimeInterval(3600)), frame, "on screen: no time limit")
        center.left("notes", at: start)
        XCTAssertEqual(center.origin("notes", at: start.addingTimeInterval(0.4)), frame, "the grid goes while the detail comes")
        XCTAssertNil(center.origin("notes", at: start.addingTimeInterval(RoomZoomCenter.memory + 0.1)))
        XCTAssertNil(center.origin("notes", at: start), "forgotten")
        // A card that comes back is known again.
        center.record("notes", frame: frame)
        center.left("notes", at: start)
        center.record("notes", frame: frame.offsetBy(dx: 5, dy: 0))
        XCTAssertEqual(center.origin("notes", at: start.addingTimeInterval(60)), frame.offsetBy(dx: 5, dy: 0))
        center.record("empty", frame: .zero)
        XCTAssertNil(center.origin("empty"))
        center.left("never", at: start)
        XCTAssertNil(center.origin("never"))
    }

    // MARK: The schedule

    // The schedule of a room is the ticks of the kit: one draw for a
    // room nobody sees, 30 a second while a motion runs.
    func testScheduleOfARoom() throws {
        let demo = try XCTUnwrap(MotionDemo.of(.requestOut))
        let sprite = SpritePlayer.aligned(start)
        let hidden = RoomSchedule(track: demo.track(mode: .none), spriteStart: sprite, motion: .none)
        XCTAssertEqual(Array(hidden.entries(from: start, mode: .normal)), [start])

        let moving = RoomSchedule(track: demo.track(), spriteStart: sprite, motion: .full)
        var ticks: [Date] = []
        for tick in moving.entries(from: start, mode: .normal) {
            if tick > start.addingTimeInterval(1.5) { break }
            ticks.append(tick)
        }
        let end = start.addingTimeInterval(0.5)
        XCTAssertEqual(ticks.filter { $0 <= end }.count, 16, "30 a second for 500 ms")
        XCTAssertTrue(ticks.contains(end), "the rest state is drawn")
        XCTAssertEqual(ticks.filter { $0 > end }.count, 8, "then the sprite loop: 8 a second")

        let reduced = RoomSchedule(track: demo.track(mode: .reduced), spriteStart: sprite, motion: .reduced)
        var fade: [Date] = []
        for tick in reduced.entries(from: start, mode: .normal) {
            if tick > start.addingTimeInterval(0.9) { break }
            fade.append(tick)
        }
        XCTAssertEqual(fade.last, start.addingTimeInterval(0.15), "the cross-fade, then nothing for the rest of the second")
    }

    // MARK: The parts

    // A room with a plain world has no canvas: the motion layer costs
    // nothing where nothing happens.
    func testAPlainRoomDrawsNoParts() {
        for pose in CharacterPose.allCases {
            let frame = RoomMotionTrack(world: RoomWorld(), pose: pose).frame(at: start)
            XCTAssertFalse(WorldBackCanvas.draws(frame), "\(pose)")
            XCTAssertFalse(WorldFrontCanvas.draws(frame), "\(pose)")
            XCTAssertEqual(frame.frost, 0)
            XCTAssertEqual(frame.light, 1)
        }
        let dark = RoomMotionTrack(world: RoomWorld.of(RoomScene.empty), pose: .sleep).frame(at: start)
        XCTAssertFalse(WorldBackCanvas.draws(dark))
        XCTAssertFalse(WorldFrontCanvas.draws(dark))
        XCTAssertEqual(dark.light, 0)
    }

    // Each room motion shows in its middle: a part is drawn, the
    // character is somewhere else, or the light, the frost or the pose
    // is between two states.
    func testEveryMotionShows() {
        for motion in WorldMotion.allCases {
            guard let demo = MotionDemo.of(motion) else { continue }
            let middle = demo.date(milliseconds: Int(demo.end().timeIntervalSince(start) * 500))
            let frame = demo.track().frame(at: middle)
            let moved = RoomPlaces.characterOffset(frame) != RoomPoint(x: 0, y: 0)
            let shows = WorldBackCanvas.draws(frame) || WorldFrontCanvas.draws(frame) || moved || frame.frost > 0
                || frame.light < 1 || frame.fromPose != nil || frame.pan > 0 || frame.spark != nil
            XCTAssertTrue(shows, motion.rawValue)
        }
    }

    // The cable of the Plumbing view: from the plug to the socket, and
    // the cover of a covered socket is where the spark stops.
    func testPlumbingCable() throws {
        let size = CGSize(width: 280, height: PlumbingCable.height)
        let plug = PlumbingCable.point(0, size: size), socket = PlumbingCable.point(1, size: size)
        XCTAssertLessThan(plug.x, socket.x)
        XCTAssertEqual(plug.y, socket.y, accuracy: 1e-9)
        XCTAssertGreaterThan(PlumbingCable.point(0.5, size: size).y, plug.y, "the cable sags a little")
        XCTAssertEqual(PlumbingCable.point(-1, size: size), plug)
        XCTAssertEqual(PlumbingCable.point(2, size: size), socket)
        let stop = PlumbingCable.point(RoomPlaces.sparkStop, size: size)
        XCTAssertLessThan(stop.x, socket.x - 20, "the spark stops before the socket")

        for device in [RoomWorld.Device(), RoomWorld.Device(calls: 2), RoomWorld.Device(calls: 1, covered: true)] {
            let renderer = ImageRenderer(content: PlumbingCable(device: device).frame(width: 280))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(device)")
            XCTAssertEqual(image.width, 560)
            XCTAssertEqual(image.height, Int(PlumbingCable.height * 2))
        }
    }

    // MARK: Pictures

    private func picture(_ freeze: MotionFreeze?, scene: RoomScene = RoomScene(tint: .cream, color: .orange, pose: .work),
                         world: RoomWorld? = nil, side: CGFloat = RoomSize.card) throws -> Data {
        let room = StagedRoom(scene: scene, icon: .app(path: nil), side: side, world: world)
            .environment(\.motionFreeze, freeze)
        let renderer = ImageRenderer(content: room)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(String(describing: freeze))")
        XCTAssertEqual(image.width, Int(side * 2))
        XCTAssertEqual(image.height, Int(side * 2))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// The share of pixels that differ between two PNG pictures of one size.
    static func pixelChange(_ a: Data, _ b: Data) throws -> Double {
        let ra = try XCTUnwrap(NSBitmapImageRep(data: a)), rb = try XCTUnwrap(NSBitmapImageRep(data: b))
        XCTAssertEqual(ra.pixelsWide, rb.pixelsWide)
        XCTAssertEqual(ra.pixelsHigh, rb.pixelsHigh)
        var changed = 0
        for y in 0..<ra.pixelsHigh {
            for x in 0..<ra.pixelsWide where ra.colorAt(x: x, y: y) != rb.colorAt(x: x, y: y) { changed += 1 }
        }
        return Double(changed) / Double(max(1, ra.pixelsWide * ra.pixelsHigh))
    }

    // Every room motion draws at its start, its middle and its end, and
    // the picture of the middle is not the picture of the start.
    func testEveryMotionRendersStartMiddleEnd() throws {
        for motion in WorldMotion.allCases {
            // A device call moves in the cable of the Plumbing view, not
            // in the room (`testDeviceCallMovesInTheCable`).
            guard let demo = MotionDemo.of(motion), motion != .spark, motion != .deviceCard else { continue }
            let length = Int((demo.end().timeIntervalSince(start) * 1000).rounded())
            let first = try picture(MotionFreeze(motion: motion, milliseconds: 0))
            let middle = try picture(MotionFreeze(motion: motion, milliseconds: length / 2))
            let last = try picture(MotionFreeze(motion: motion, milliseconds: length))
            XCTAssertNotEqual(first, middle, "\(motion.rawValue): the middle differs from the start")
            XCTAssertNotEqual(first, last, "\(motion.rawValue): the end differs from the start")
            // A frozen moment is the same picture every time. The renderer
            // can smooth a few edge pixels differently from one draw to the
            // next (the frost is a blur), so up to 2% of the pixels may differ.
            let again = try picture(MotionFreeze(motion: motion, milliseconds: length / 2))
            XCTAssertLessThan(try Self.pixelChange(again, middle), 0.02, motion.rawValue)
        }
    }

    // A device call: the spark is on the cable in the middle of the
    // motion and gone at its end; at a covered socket the card is up.
    func testDeviceCallMovesInTheCable() throws {
        func cable(_ freeze: MotionFreeze) throws -> Data {
            let view = PlumbingCable(device: RoomWorld.Device()).frame(width: 280).environment(\.motionFreeze, freeze)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(freeze)")
            return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        let before = try cable(MotionFreeze(motion: .spark, milliseconds: 0))
        let middle = try cable(MotionFreeze(motion: .spark, milliseconds: 200))
        let after = try cable(MotionFreeze(motion: .spark, milliseconds: 400))
        XCTAssertNotEqual(middle, before)
        XCTAssertNotEqual(middle, after, "the spark is gone at the end")
        let stopped = try cable(MotionFreeze(motion: .deviceCard, milliseconds: 399))
        let risen = try cable(MotionFreeze(motion: .deviceCard, milliseconds: 650))
        XCTAssertNotEqual(stopped, risen, "the card rises after the spark")
        XCTAssertNotEqual(risen, after, "a covered socket has its cover and its card")
    }

    // A room at rest shows its world: frost on a frozen room, and a
    // room without light is darker.
    func testARoomAtRestShowsItsWorld() throws {
        // A room at rest in a test run draws its world with no motion.
        let frozen = try picture(nil, scene: RoomScene(tint: .cream, color: .orange, pose: .sleep),
                                 world: RoomWorld(lit: false, frozen: true))
        let plain = try picture(nil, scene: RoomScene(tint: .cream, color: .orange, pose: .sleep), world: RoomWorld(lit: false))
        XCTAssertNotEqual(frozen, plain, "frost shows on a frozen room")
        let lit = try picture(nil, scene: RoomScene(tint: .cream, color: .orange, pose: .sleep), world: RoomWorld(lit: true))
        XCTAssertNotEqual(lit, plain, "a room without light is darker")
    }

    // Every part of the world draws at the sizes of the app: the card,
    // the detail header, the agent header and the welcome.
    func testAFullWorldRendersAtEverySize() throws {
        let world = RoomWorld(lit: true, request: RoomWorld.Request(created: start, expires: start.addingTimeInterval(300)),
                              network: .limited, mail: .question, frozen: false,
                              loft: RoomWorld.Loft(notebooks: 9), device: RoomWorld.Device(calls: 1, covered: true),
                              child: true, changes: true, applied: 2)
        for side in [RoomSize.card, RoomSize.header, RoomSize.welcome, 88, RoomSize.maxCardWidth] {
            for tint in RoomTint.allCases {
                _ = try picture(nil, scene: RoomScene(tint: tint, color: .blue, pose: .wait, badge: 2), world: world, side: side)
            }
        }
        var loft = world
        loft.request = nil
        loft.loft = RoomWorld.Loft(notebooks: 2, writing: true)
        _ = try picture(nil, scene: RoomScene(tint: .mint, color: .pink, pose: .work), world: loft)
    }

    // MARK: The snapshot switch

    #if DEBUG
    func testSnapshotMotionSwitch() {
        let name = MotionFreezeSetting.variable
        XCTAssertEqual(name, "PADDOCK_LAUNCHER_SNAPSHOT_MOTION")
        XCTAssertEqual(SnapshotDump.motionFreeze([name: "request-out@250"]), MotionFreeze(motion: .requestOut, milliseconds: 250))
        XCTAssertEqual(SnapshotDump.motionFreeze([name: "zoom@0"]), MotionFreeze(motion: .zoom, milliseconds: 0))
        XCTAssertNil(SnapshotDump.motionFreeze([name: "request-out"]))
        XCTAssertNil(SnapshotDump.motionFreeze([name: "dance@250"]))
        XCTAssertNil(SnapshotDump.motionFreeze([:]))
        XCTAssertEqual(MotionGallery.caption(MotionFreeze(motion: .freeze, milliseconds: 300)), "freeze at 300 ms")
    }

    // The gallery window of a snapshot draws for every motion.
    func testGalleryRenders() throws {
        for motion in WorldMotion.allCases {
            let gallery = MotionGallery(freeze: MotionFreeze(motion: motion, milliseconds: motion.milliseconds / 2))
            let renderer = ImageRenderer(content: gallery)
            renderer.scale = 1
            XCTAssertNotNil(renderer.cgImage, motion.rawValue)
        }
    }
    #endif
}
