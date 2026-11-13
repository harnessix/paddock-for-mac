import Foundation
import XCTest
@testable import PaddockKit

/// The motion of the world on a fake clock: each motion at its start, its
/// middle and its end, Reduce Motion, no work for a hidden or offscreen
/// room, and the rest state each motion ends in.
final class WorldMotionTests: XCTestCase {
    let start = MotionDemo.start

    func at(_ milliseconds: Int) -> Date {
        start.addingTimeInterval(Double(milliseconds) / 1000)
    }

    func demo(_ motion: WorldMotion, file: StaticString = #filePath, line: UInt = #line) -> MotionDemo {
        guard let demo = MotionDemo.of(motion) else {
            XCTFail("\(motion) has no demo", file: file, line: line)
            return MotionDemo(motion: motion, from: RoomWorld(), fromPose: .idle, to: RoomWorld(), toPose: .idle)
        }
        return demo
    }

    // MARK: The lengths and the curves

    // The lengths of the brief, in milliseconds.
    func testLengthsOfTheBrief() {
        let brief: [WorldMotion: Int] = [
            .requestOut: 500, .requestBack: 400, .network: 300, .flagUp: 200,
            .freeze: 600, .thaw: 600, .climb: 600, .notebook: 250, .spark: 400,
            .spawn: 800, .envelope: 500, .apply: 700, .zoom: 450, .loftPan: 350,
        ]
        for (motion, milliseconds) in brief {
            XCTAssertEqual(motion.milliseconds, milliseconds, motion.rawValue)
            XCTAssertEqual(motion.duration, Double(milliseconds) / 1000, accuracy: 1e-12)
        }
        XCTAssertEqual(WorldMotion.reducedFadeMilliseconds, 150)
        XCTAssertEqual(WorldMotion.fps, 30)
        XCTAssertEqual(SpritePlayer.fps, 8)
        XCTAssertEqual(WorldMotion.zoom.curve, .spring(bounce: 0.12))
    }

    // Short and calm: no motion is longer than 800 ms, and none is
    // shorter than a few display frames.
    func testEveryMotionIsShort() {
        for motion in WorldMotion.allCases {
            XCTAssertLessThanOrEqual(motion.milliseconds, WorldMotion.longestMilliseconds, motion.rawValue)
            XCTAssertGreaterThanOrEqual(motion.milliseconds, 150, motion.rawValue)
        }
    }

    // The names of the snapshot switch are all different and have no
    // capital letter or space.
    func testNamesAreForAShell() {
        XCTAssertEqual(Set(MotionFreeze.names).count, WorldMotion.allCases.count)
        for name in MotionFreeze.names {
            XCTAssertEqual(name, name.lowercased())
            XCTAssertFalse(name.contains(" ") || name.contains("@"), name)
        }
    }

    // Every curve starts at exactly 0 and ends at exactly 1. The eases
    // never go back. A spring goes a little past the end and comes back:
    // never busy.
    func testCurves() {
        let curves: [MotionCurve] = [.linear, .easeIn, .easeOut, .easeInOut, .spring(bounce: 0), .spring(bounce: 0.12),
                                     .spring(bounce: 0.25)]
        for curve in curves {
            XCTAssertEqual(curve.value(0), 0, "\(curve)")
            XCTAssertEqual(curve.value(1), 1, "\(curve)")
            XCTAssertEqual(curve.value(-1), 0, "\(curve)")
            XCTAssertEqual(curve.value(2), 1, "\(curve)")
            var last = 0.0
            var most = 0.0
            for step in 0...200 {
                let value = curve.value(Double(step) / 200)
                most = max(most, value)
                if case .spring = curve {} else {
                    XCTAssertGreaterThanOrEqual(value, last - 1e-12, "\(curve) at \(step)")
                }
                last = value
            }
            XCTAssertLessThanOrEqual(most, 1.06, "\(curve) overshoots")
            XCTAssertEqual(curve.value(0.999), 1, accuracy: 0.01, "\(curve) is at rest at its end")
        }
        XCTAssertEqual(MotionCurve.spring(bounce: 0).value(0.5), MotionCurve.spring(bounce: 0).value(0.5))
        XCTAssertLessThanOrEqual((0...200).map { MotionCurve.spring(bounce: 0).value(Double($0) / 200) }.max() ?? 2, 1.0001,
                                 "no bounce, no overshoot")
        XCTAssertGreaterThan((0...200).map { MotionCurve.spring(bounce: 0.25).value(Double($0) / 200) }.max() ?? 0, 1.001)
        XCTAssertEqual(MotionCurve.easeInOut.value(0.5), 0.5, accuracy: 1e-12)
    }

    // MARK: Start, middle, end of every motion

    // Each room motion: at its start the room is as before, in its
    // middle it is between, and at its end it is exactly the room at rest
    // in the new world. Nothing moves after the end.
    func testEveryMotionEndsInItsRestState() {
        for motion in WorldMotion.allCases {
            guard let demo = MotionDemo.of(motion) else {
                XCTAssertTrue(MotionDemo.roomless.contains(motion), motion.rawValue)
                continue
            }
            let before = RoomMotionTrack(world: demo.from, pose: demo.fromPose)
            let track = demo.track()
            let end = demo.end()
            XCTAssertGreaterThan(end, start, motion.rawValue)
            XCTAssertLessThanOrEqual(end.timeIntervalSince(start), 0.8 + 1e-9, motion.rawValue)

            // Start: the room of before, but for the pose rule of a
            // moving character.
            var first = track.frame(at: start)
            let was = before.frame(at: start)
            XCTAssertTrue(track.isMoving(at: start), motion.rawValue)
            first.pose = was.pose
            first.fromPose = nil
            first.poseBlend = 1
            first.heldAt = was.heldAt
            first.notebooks = was.notebooks
            first.notebookSlide = was.notebookSlide
            first.spark = nil
            first.envelope = nil
            first.apply = nil
            first.covered = was.covered
            first.ring = was.ring
            XCTAssertEqual(first, was, "\(motion.rawValue) starts where the room was")

            // Middle: not the start and not the end.
            let middle = track.frame(at: start.addingTimeInterval(end.timeIntervalSince(start) / 2))
            XCTAssertNotEqual(middle, track.frame(at: start), "\(motion.rawValue) moves")
            XCTAssertNotEqual(middle, track.frame(at: end), "\(motion.rawValue) is not done in its middle")

            // End: the rest state, and it stays.
            XCTAssertFalse(track.isMoving(at: end), motion.rawValue)
            var last = track.frame(at: end)
            var rest = demo.rest.frame(at: end)
            if demo.to.frozen {
                // A frozen character keeps the pose it had.
                XCTAssertEqual(last.pose, demo.fromPose, motion.rawValue)
                XCTAssertEqual(last.heldAt, start, motion.rawValue)
                last.pose = rest.pose
                last.heldAt = nil
                rest.heldAt = nil
            }
            XCTAssertEqual(last, rest, "\(motion.rawValue) ends in its rest state")
            XCTAssertEqual(track.frame(at: end.addingTimeInterval(60)).walk, rest.walk)
            var later = track.frame(at: end.addingTimeInterval(0.5))
            var restLater = demo.rest.frame(at: end.addingTimeInterval(0.5))
            if demo.to.frozen {
                later.pose = restLater.pose
                later.heldAt = nil
                restLater.heldAt = nil
            }
            XCTAssertEqual(later, restLater, "\(motion.rawValue) stays at rest")
            XCTAssertNil(track.snapshot(at: end).previous, motion.rawValue)
        }
    }

    // A room at rest does not move, whatever its world.
    func testARoomAtRestHasNoMotion() {
        for motion in WorldMotion.allCases {
            guard let demo = MotionDemo.of(motion) else { continue }
            for track in [RoomMotionTrack(world: demo.from, pose: demo.fromPose), demo.rest] {
                XCTAssertNil(track.motionEnd, motion.rawValue)
                XCTAssertFalse(track.isMoving(at: start))
            }
        }
        // The same world again starts nothing.
        var track = RoomMotionTrack(world: RoomWorld(changes: true), pose: .work)
        track.set(RoomWorld(changes: true), pose: .work, at: start, mode: .full)
        XCTAssertNil(track.motionEnd)
    }

    // MARK: A request

    // The character walks to the door with the amber card in 500 ms,
    // then waits with a ring for the time left. It is on its feet while
    // it walks, and the "!" loop starts when it arrives.
    func testRequestWalksToTheDoor() {
        let track = demo(.requestOut).track()
        let first = track.frame(at: start)
        XCTAssertEqual(first.walk, 0)
        XCTAssertEqual(first.card, 0)
        XCTAssertNil(first.ring)
        XCTAssertEqual(RoomPlaces.characterOffset(first), RoomPoint(x: 0, y: 0))

        let middle = track.frame(at: at(250))
        XCTAssertEqual(middle.walk, 0.5, accuracy: 1e-5, "ease in and out: half way at half time")
        XCTAssertEqual(middle.card, 1, "the card is in the hand after 150 ms")
        XCTAssertEqual(middle.pose, .idle)
        XCTAssertTrue(middle.isWalking)
        XCTAssertNil(middle.ring, "no ring on the way")
        XCTAssertEqual(RoomPlaces.characterOffset(middle).x, RoomPlaces.door.x / 2, accuracy: 1e-5)
        XCTAssertLessThan(RoomPlaces.characterOffset(middle).y, RoomPlaces.door.y / 2, "a step lifts the character")

        XCTAssertTrue(track.isMoving(at: at(499)))
        let last = track.frame(at: at(500))
        XCTAssertEqual(last.walk, 1)
        XCTAssertEqual(last.step, 0, accuracy: 1e-5, "both feet on the floor")
        XCTAssertEqual(last.pose, .wait)
        XCTAssertFalse(last.isWalking)
        XCTAssertEqual(RoomPlaces.characterOffset(last).x, RoomPlaces.door.x, accuracy: 1e-5)
        XCTAssertEqual(RoomPlaces.characterOffset(last).y, RoomPlaces.door.y, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(last.ring), 1 - 0.5 / 300, accuracy: 1e-5)
        XCTAssertFalse(track.isMoving(at: at(500)))

        // The ring runs down with the time of the request and stops at 0.
        XCTAssertEqual(try XCTUnwrap(track.frame(at: at(150_000)).ring), 0.5, accuracy: 1e-5)
        XCTAssertEqual(track.frame(at: at(400_000)).ring, 0)
        XCTAssertTrue(track.isAmbient(at: at(150_000)))
        XCTAssertFalse(track.isAmbient(at: at(400_000)))
    }

    // A request without a time limit has no ring.
    func testRequestWithoutATimeHasNoRing() {
        var track = RoomMotionTrack(world: RoomWorld(), pose: .work)
        track.set(RoomWorld(request: RoomWorld.Request()), pose: .wait, at: start, mode: .full)
        XCTAssertNil(track.frame(at: at(500)).ring)
        XCTAssertEqual(track.frame(at: at(500)).walk, 1)
        XCTAssertNil(RoomWorld.Request(created: start, expires: start).left(at: start))
    }

    // After the answer the character walks back in 400 ms without the card.
    func testAnswerWalksBack() {
        let track = demo(.requestBack).track()
        XCTAssertEqual(track.frame(at: start).walk, 1)
        XCTAssertEqual(track.frame(at: start).card, 1)
        let middle = track.frame(at: at(200))
        XCTAssertEqual(middle.walk, 0.5, accuracy: 1e-5)
        XCTAssertEqual(middle.card, 0, "the card stayed at the door")
        XCTAssertEqual(middle.pose, .idle)
        XCTAssertNil(middle.ring)
        XCTAssertTrue(track.isMoving(at: at(399)))
        let last = track.frame(at: at(400))
        XCTAssertEqual(last.walk, 0)
        XCTAssertEqual(last.pose, .work)
        XCTAssertFalse(track.isMoving(at: at(400)))
    }

    // An answer that comes while the character still walks to the door:
    // it turns where it is. No jump.
    func testAChangeInTheMiddleGoesOnFromThere() {
        var track = demo(.requestOut).track()
        let there = track.frame(at: at(250)).walk
        track.set(RoomWorld(), pose: .work, at: at(250), mode: .full)
        XCTAssertEqual(track.frame(at: at(250)).walk, there, accuracy: 1e-5)
        XCTAssertLessThan(track.frame(at: at(450)).walk, there)
        XCTAssertEqual(track.frame(at: at(650)).walk, 0)
        XCTAssertEqual(track.frame(at: at(650)), RoomMotionTrack(world: RoomWorld(), pose: .work).frame(at: at(650)))
        XCTAssertEqual(track.motionEnd, at(650))
    }

    // MARK: The window, the mailbox

    // The blind of the window takes 300 ms: up for the internet, half
    // down for some servers, down for no network.
    func testNetworkMovesTheBlind() {
        XCTAssertEqual(RoomWorld.Network.allCases.map(\.shade), [0, 0.5, 1])
        let track = demo(.network).track()
        XCTAssertEqual(track.frame(at: start).shade, 0)
        let middle = track.frame(at: at(150)).shade
        XCTAssertGreaterThan(middle, 0.5, "ease out: more than half way at half time")
        XCTAssertLessThan(middle, 1)
        XCTAssertEqual(track.frame(at: at(300)).shade, 1)
        XCTAssertEqual(track.motionEnd, at(300))

        var limited = RoomMotionTrack(world: RoomWorld(network: .closed), pose: .work)
        limited.set(RoomWorld(network: .limited), pose: .work, at: start, mode: .full)
        XCTAssertEqual(limited.frame(at: at(300)).shade, 0.5)
        // A room that does not say its network has a clear window.
        XCTAssertEqual(RoomMotionTrack(world: RoomWorld(), pose: .work).frame(at: start).shade, 0)
    }

    // The flag goes up in 200 ms. A message does not move the box.
    func testFlagGoesUp() {
        let track = demo(.flagUp).track()
        XCTAssertTrue(track.frame(at: start).mailbox)
        XCTAssertEqual(track.frame(at: start).flag, 0)
        XCTAssertGreaterThan(track.frame(at: at(100)).flag, 0.5)
        XCTAssertEqual(track.frame(at: at(200)).flag, 1)
        XCTAssertEqual(track.motionEnd, at(200))
        for milliseconds in stride(from: 0, through: 400, by: 20) {
            XCTAssertEqual(track.frame(at: at(milliseconds)).hop, 0)
        }
        let down = demo(.flagDown).track()
        XCTAssertEqual(down.frame(at: start).flag, 1)
        XCTAssertEqual(down.frame(at: at(200)).flag, 0)
        // A room with no mailbox draws none.
        XCTAssertFalse(RoomMotionTrack(world: RoomWorld(), pose: .work).frame(at: start).mailbox)
    }

    // For a question the box hops once: up, down, and it stays down.
    func testBoxHopsOnceForAQuestion() {
        let track = demo(.boxHop).track()
        XCTAssertEqual(track.frame(at: start).hop, 0, accuracy: 1e-5)
        XCTAssertEqual(track.frame(at: at(160)).hop, 1, accuracy: 1e-5, "the top of the hop")
        XCTAssertEqual(track.frame(at: at(320)).hop, 0)
        XCTAssertEqual(track.frame(at: at(200)).flag, 1)
        var peaks = 0
        var rising = false
        var last = 0.0
        for milliseconds in stride(from: 0, through: 1000, by: 10) {
            let hop = track.frame(at: at(milliseconds)).hop
            if hop > last + 1e-9 { rising = true }
            if hop < last - 1e-9, rising {
                peaks += 1
                rising = false
            }
            last = hop
        }
        XCTAssertEqual(peaks, 1, "one hop")
        // A second question while the first waits does not hop again.
        var again = track
        again.set(RoomWorld(mail: .question, changes: true), pose: .work, at: at(2000), mode: .full)
        XCTAssertEqual(again.frame(at: at(2100)).hop, 0)
    }

    // MARK: Freeze and thaw

    // Frost grows in 600 ms. The character keeps the pose and the frame
    // it had: the loop is held at the moment of the freeze.
    func testFreezeKeepsThePose() {
        let track = demo(.freeze).track()
        XCTAssertEqual(track.frame(at: start).frost, 0)
        let middle = track.frame(at: at(300))
        XCTAssertGreaterThan(middle.frost, 0.5)
        XCTAssertLessThan(middle.frost, 1)
        XCTAssertEqual(middle.pose, .work, "not the sleep pose of the suspended state")
        XCTAssertNil(middle.fromPose)
        XCTAssertEqual(middle.heldAt, start)
        let last = track.frame(at: at(600))
        XCTAssertEqual(last.frost, 1)
        XCTAssertEqual(last.pose, .work)
        XCTAssertEqual(last.heldAt, start)
        XCTAssertEqual(last.light, 0, "a frozen room is dark")
        XCTAssertEqual(track.motionEnd, at(600))

        // A pose change of a frozen room does not show.
        var changed = track
        changed.set(RoomWorld(lit: false, frozen: true), pose: .blocked, at: at(1000), mode: .full)
        XCTAssertEqual(changed.frame(at: at(1100)).pose, .work)
        XCTAssertNil(changed.motionEnd)

        // A room that is frozen when it comes on screen holds the first
        // frame of its pose.
        let cold = RoomMotionTrack(world: RoomWorld(lit: false, frozen: true), pose: .sleep).frame(at: start)
        XCTAssertEqual(cold.pose, .sleep)
        XCTAssertEqual(cold.heldAt, SpritePlayer.epoch)
        XCTAssertEqual(SpritePlayer(frameCount: 4, start: start).frame(at: SpritePlayer.epoch, playing: true), 0)
    }

    // The frost melts in 600 ms, the loop plays again and the pose of
    // the state comes back in a cross-fade.
    func testThawMeltsAndWakes() {
        var track = demo(.freeze).track()
        track.set(RoomWorld(), pose: .idle, at: at(5000), mode: .full)
        let first = track.frame(at: at(5000))
        XCTAssertEqual(first.frost, 1)
        XCTAssertNil(first.heldAt, "the loop plays again")
        XCTAssertEqual(first.fromPose, .work)
        XCTAssertEqual(first.pose, .idle)
        XCTAssertEqual(first.poseBlend, 0)
        let middle = track.frame(at: at(5300))
        XCTAssertGreaterThan(middle.frost, 0)
        XCTAssertLessThan(middle.frost, 0.5)
        XCTAssertNil(middle.fromPose, "the cross-fade of the pose is done")
        XCTAssertEqual(track.frame(at: at(5600)).frost, 0)
        XCTAssertEqual(track.frame(at: at(5600)), RoomMotionTrack(world: RoomWorld(), pose: .idle).frame(at: at(5600)))
    }

    // MARK: The loft

    // The character goes to the ladder, climbs it and writes: 600 ms.
    // The view pans up in 350 ms.
    func testClimbToTheLoft() {
        let track = demo(.climb).track()
        let first = track.frame(at: start)
        XCTAssertTrue(first.hasLoft)
        XCTAssertEqual(first.climb, 0)
        XCTAssertEqual(first.pan, 0)
        XCTAssertEqual(first.notebooks, 3)

        let middle = track.frame(at: at(300))
        XCTAssertEqual(middle.climb, 0.5, accuracy: 1e-5)
        XCTAssertEqual(middle.pose, .idle)
        let place = RoomPlaces.characterOffset(middle)
        XCTAssertEqual(place.x, RoomPlaces.ladderFoot.x, accuracy: 1e-5, "on the ladder")
        XCTAssertLessThan(place.y, RoomPlaces.ladderFoot.y)
        XCTAssertGreaterThan(place.y, RoomPlaces.hatch.y)
        XCTAssertGreaterThan(middle.pan, 0.9, "the view is nearly there")
        XCTAssertEqual(track.frame(at: at(350)).pan, 1)

        let last = track.frame(at: at(600))
        XCTAssertEqual(last.climb, 1)
        XCTAssertEqual(last.pose, .work, "it writes")
        XCTAssertEqual(RoomPlaces.characterOffset(last), RoomPlaces.loftSeat)
        XCTAssertEqual(track.motionEnd, at(600))

        let down = demo(.descend).track()
        XCTAssertEqual(down.frame(at: start).climb, 1)
        XCTAssertEqual(down.frame(at: at(600)).climb, 0)
        XCTAssertEqual(down.frame(at: at(600)).pan, 0)
        XCTAssertEqual(RoomPlaces.characterOffset(down.frame(at: at(600))), RoomPoint(x: 0, y: 0))
    }

    // The way to the loft passes the foot of the ladder and the hatch.
    func testClimbPath() {
        let path = RoomPlaces.climbPath
        XCTAssertEqual(path.point(0), RoomPoint(x: 0, y: 0))
        XCTAssertEqual(path.point(0.22), RoomPlaces.ladderFoot)
        XCTAssertEqual(path.point(0.88), RoomPlaces.hatch)
        XCTAssertEqual(path.point(1), RoomPlaces.loftSeat)
        XCTAssertEqual(path.point(-1), RoomPoint(x: 0, y: 0))
        XCTAssertEqual(path.point(2), RoomPlaces.loftSeat)
        XCTAssertEqual(path.point(0.11).x, RoomPlaces.ladderFoot.x / 2, accuracy: 1e-5)
        XCTAssertLessThan(RoomPlaces.hatch.y, -RoomPlaces.size / 2, "the hatch is in the square of the loft")
    }

    // A request wins over the loft: the character comes down to the door.
    func testARequestBringsTheCharacterDown() {
        var track = demo(.climb).track()
        let request = RoomWorld.Request(created: at(2000), expires: at(302_000))
        track.set(RoomWorld(request: request, loft: RoomWorld.Loft(notebooks: 3, writing: true)), pose: .wait, at: at(2000), mode: .full)
        let last = track.frame(at: at(2600))
        XCTAssertEqual(last.climb, 0)
        XCTAssertEqual(last.walk, 1)
        XCTAssertEqual(last.pan, 0)
        XCTAssertEqual(last.pose, .wait)
    }

    // A new notebook slides onto the shelf in 250 ms. The first look at
    // a shelf slides nothing.
    func testNotebookSlidesOntoTheShelf() {
        let track = demo(.notebook).track()
        let first = track.frame(at: start)
        XCTAssertEqual(first.notebooks, 4)
        XCTAssertEqual(first.notebookSlide, 0)
        XCTAssertGreaterThan(track.frame(at: at(125)).notebookSlide, 0.5)
        XCTAssertLessThan(track.frame(at: at(125)).notebookSlide, 1)
        XCTAssertEqual(track.frame(at: at(250)).notebookSlide, 1)
        XCTAssertEqual(track.motionEnd, at(250))

        var fresh = RoomMotionTrack(world: RoomWorld(), pose: .work)
        fresh.set(RoomWorld(loft: RoomWorld.Loft(notebooks: 5)), pose: .work, at: start, mode: .full)
        XCTAssertEqual(fresh.frame(at: start).notebookSlide, 1)
        XCTAssertNil(fresh.motionEnd)
    }

    // The pan alone: you look at the loft while the character works below.
    func testLoftPan() {
        let track = demo(.loftPan).track()
        XCTAssertEqual(track.frame(at: start).pan, 0)
        XCTAssertEqual(track.frame(at: at(175)).pan, 0.5, accuracy: 1e-5)
        XCTAssertEqual(track.frame(at: at(350)).pan, 1)
        XCTAssertEqual(track.frame(at: at(350)).climb, 0)
        XCTAssertEqual(track.motionEnd, at(350))
        // Without a loft there is nothing to look at.
        XCTAssertFalse(RoomWorld(showsLoft: true).looksAtLoft)
    }

    // MARK: A device call

    // The spark runs the whole cable in 400 ms and is gone.
    func testSparkRunsTheCable() {
        let track = demo(.spark).track()
        XCTAssertTrue(track.frame(at: start).device)
        XCTAssertEqual(track.frame(at: start).spark, 0)
        XCTAssertEqual(try XCTUnwrap(track.frame(at: at(200)).spark), 0.5, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(track.frame(at: at(399)).spark), 1, accuracy: 0.01)
        XCTAssertNil(track.frame(at: at(400)).spark)
        XCTAssertEqual(track.frame(at: at(400)).deviceCard, 0)
        XCTAssertEqual(track.motionEnd, at(400))
        XCTAssertNil(RoomMotionTrack(world: RoomWorld(), pose: .work).frame(at: start).spark)
    }

    // At a covered socket the spark stops at the cover, and then a card rises.
    func testSparkStopsAtACoveredSocket() {
        let track = demo(.deviceCard).track()
        XCTAssertTrue(track.frame(at: start).covered)
        for milliseconds in stride(from: 0, to: 400, by: 10) {
            let frame = track.frame(at: at(milliseconds))
            XCTAssertLessThanOrEqual(try XCTUnwrap(frame.spark), RoomPlaces.sparkStop + 1e-9)
            XCTAssertEqual(frame.deviceCard, 0, "the card waits for the spark")
        }
        XCTAssertEqual(try XCTUnwrap(track.frame(at: at(399)).spark), RoomPlaces.sparkStop, accuracy: 0.01)
        XCTAssertNil(track.frame(at: at(400)).spark)
        XCTAssertGreaterThan(track.frame(at: at(525)).deviceCard, 0.5)
        XCTAssertEqual(track.frame(at: at(650)).deviceCard, 1)
        XCTAssertEqual(track.motionEnd, at(650))

        // The answer uncovers the socket: the card goes down.
        var answered = track
        answered.set(RoomWorld(device: RoomWorld.Device(calls: 1)), pose: .work, at: at(2000), mode: .full)
        XCTAssertEqual(answered.frame(at: at(2250)).deviceCard, 0)
        XCTAssertNil(answered.frame(at: at(2100)).spark, "no new call, no spark")
    }

    // MARK: Spawn

    // The child room builds in 800 ms. When it ends, an envelope comes
    // home in 500 ms and the child room goes.
    func testSpawnBuildsAndTheEnvelopeReturns() {
        let build = demo(.spawn).track()
        XCTAssertEqual(build.frame(at: start).build, 0)
        XCTAssertGreaterThan(build.frame(at: at(400)).build, 0.5)
        XCTAssertLessThan(build.frame(at: at(400)).build, 1)
        XCTAssertEqual(build.frame(at: at(800)).build, 1)
        XCTAssertNil(build.frame(at: at(400)).envelope)
        XCTAssertEqual(build.motionEnd, at(800))

        let back = demo(.envelope).track()
        XCTAssertEqual(back.frame(at: start).envelope, 0)
        XCTAssertEqual(back.frame(at: start).build, 1)
        XCTAssertEqual(try XCTUnwrap(back.frame(at: at(250)).envelope), 0.5, accuracy: 1e-5)
        XCTAssertNil(back.frame(at: at(500)).envelope)
        XCTAssertEqual(back.frame(at: at(500)).build, 0)
        XCTAssertEqual(back.motionEnd, at(500))
    }

    // MARK: The copy

    // The model glows while changes wait. Apply moves the parts in
    // 700 ms, and the glow goes.
    func testGlowAndApply() {
        let glow = demo(.glow).track()
        XCTAssertEqual(glow.frame(at: start).glow, 0)
        XCTAssertEqual(glow.frame(at: at(300)).glow, 1)
        XCTAssertEqual(glow.frame(at: at(60_000)).glow, 1, "it glows as long as the changes wait")
        XCTAssertTrue(glow.isAmbient(at: at(60_000)))

        let apply = demo(.apply).track()
        XCTAssertEqual(apply.frame(at: start).apply, 0)
        XCTAssertEqual(apply.frame(at: start).glow, 1)
        XCTAssertEqual(try XCTUnwrap(apply.frame(at: at(350)).apply), 0.5, accuracy: 1e-5)
        XCTAssertEqual(apply.frame(at: at(350)).glow, 0)
        XCTAssertNil(apply.frame(at: at(700)).apply)
        XCTAssertEqual(apply.motionEnd, at(700))
        XCTAssertFalse(apply.isAmbient(at: at(700)))

        // Changes that go away without an apply: the glow goes, no parts.
        var dropped = RoomMotionTrack(world: RoomWorld(changes: true), pose: .work)
        dropped.set(RoomWorld(), pose: .work, at: start, mode: .full)
        XCTAssertNil(dropped.frame(at: at(100)).apply)
        XCTAssertEqual(dropped.frame(at: at(300)).glow, 0)
    }

    // The breath of the glow is slow and small.
    func testBreathIsCalm() {
        var low = 2.0, high = 0.0
        for step in 0..<240 {
            let breath = RoomMotionFrame.breath(at: start.addingTimeInterval(Double(step) / 100))
            low = min(low, breath)
            high = max(high, breath)
        }
        XCTAssertEqual(low, 0.7, accuracy: 0.001)
        XCTAssertEqual(high, 1, accuracy: 0.001)
        // Between two ticks of the sprite grid the glow changes by less
        // than a twentieth.
        for step in 0..<40 {
            let a = RoomMotionFrame.breath(at: start.addingTimeInterval(Double(step) / 8))
            let b = RoomMotionFrame.breath(at: start.addingTimeInterval(Double(step + 1) / 8))
            XCTAssertLessThan(abs(a - b), 0.05)
        }
    }

    // MARK: Start and stop

    // Start: the light turns on and the character wakes. Stop: the light
    // dims and the mask comes down.
    func testLightAndWake() {
        let on = demo(.lightOn).track()
        let first = on.frame(at: start)
        XCTAssertEqual(first.light, 0)
        XCTAssertEqual(first.fromPose, .sleep)
        XCTAssertEqual(first.pose, .idle)
        XCTAssertEqual(first.poseBlend, 0)
        let middle = on.frame(at: at(120))
        XCTAssertGreaterThan(middle.poseBlend, 0.5)
        XCTAssertLessThan(middle.poseBlend, 1)
        XCTAssertEqual(middle.fromPose, .sleep)
        XCTAssertNil(on.frame(at: at(240)).fromPose)
        XCTAssertEqual(on.frame(at: at(240)).poseBlend, 1)
        XCTAssertGreaterThan(on.frame(at: at(200)).light, 0.5)
        XCTAssertEqual(on.frame(at: at(400)).light, 1)
        XCTAssertEqual(on.motionEnd, at(400))

        let off = demo(.lightOff).track()
        XCTAssertEqual(off.frame(at: start).light, 1)
        XCTAssertEqual(off.frame(at: start).fromPose, .idle)
        XCTAssertEqual(off.frame(at: start).pose, .sleep)
        XCTAssertEqual(off.frame(at: at(400)).light, 0)
        XCTAssertEqual(off.frame(at: at(400)).pose, .sleep)
        XCTAssertNil(off.frame(at: at(400)).fromPose)
    }

    // MARK: Reduce Motion

    // With Reduce Motion every state swaps at once, under a cross-fade
    // of 150 ms from the picture before.
    func testReduceMotionIsACrossFade() {
        for motion in WorldMotion.allCases {
            guard let demo = MotionDemo.of(motion) else { continue }
            let before = RoomMotionTrack(world: demo.from, pose: demo.fromPose).frame(at: start)
            let track = demo.track(mode: .reduced)
            XCTAssertEqual(track.motionEnd, at(150), motion.rawValue)

            // The state is the new one at once: nothing travels.
            var rest = demo.rest.frame(at: start)
            var first = track.snapshot(at: start)
            if demo.to.frozen {
                XCTAssertEqual(first.frame.pose, demo.fromPose)
                first.frame.pose = rest.pose
                first.frame.heldAt = nil
                rest.heldAt = nil
            }
            XCTAssertEqual(first.frame, rest, motion.rawValue)
            XCTAssertEqual(first.previous, before, motion.rawValue)
            XCTAssertEqual(first.fade, 0, motion.rawValue)
            XCTAssertFalse(first.frame.isWalking)
            XCTAssertNil(first.frame.spark)
            XCTAssertNil(first.frame.envelope)
            XCTAssertNil(first.frame.apply)
            XCTAssertNil(first.frame.fromPose)
            XCTAssertEqual(first.frame.hop, 0)
            XCTAssertEqual(first.frame.notebookSlide, 1)

            let middle = track.snapshot(at: at(75))
            XCTAssertEqual(middle.fade, 0.5, accuracy: 1e-5, motion.rawValue)
            XCTAssertEqual(middle.previous, before, motion.rawValue)

            let last = track.snapshot(at: at(150))
            XCTAssertNil(last.previous, motion.rawValue)
            XCTAssertEqual(last.fade, 1, motion.rawValue)
            XCTAssertFalse(track.isMoving(at: at(150)), motion.rawValue)
        }
    }

    // MARK: No work for a room nobody sees

    // The mode of a room: full only in a visible window, on screen,
    // without Reduce Motion and outside a UI test.
    func testModeOfARoom() {
        XCTAssertEqual(RoomMotionMode.of(windowVisible: true, onScreen: true, reduceMotion: false), .full)
        XCTAssertEqual(RoomMotionMode.of(windowVisible: true, onScreen: true, reduceMotion: true), .reduced)
        XCTAssertEqual(RoomMotionMode.of(windowVisible: false, onScreen: true, reduceMotion: false), .none)
        XCTAssertEqual(RoomMotionMode.of(windowVisible: true, onScreen: false, reduceMotion: false), .none)
        XCTAssertEqual(RoomMotionMode.of(windowVisible: false, onScreen: false, reduceMotion: true), .none)
        XCTAssertEqual(RoomMotionMode.of(windowVisible: true, onScreen: true, reduceMotion: false, still: true), .none)
    }

    // A hidden or offscreen room takes the new state at once: no move
    // runs, no cross-fade, and it draws once.
    func testAHiddenRoomDoesNoWork() {
        for motion in WorldMotion.allCases {
            guard let demo = MotionDemo.of(motion) else { continue }
            let track = demo.track(mode: .none)
            XCTAssertNil(track.motionEnd, motion.rawValue)
            XCTAssertFalse(track.isMoving(at: start), motion.rawValue)
            XCTAssertNil(track.snapshot(at: start).previous, motion.rawValue)
            var frame = track.frame(at: start)
            var rest = demo.rest.frame(at: start)
            if demo.to.frozen {
                frame.pose = rest.pose
                frame.heldAt = nil
                rest.heldAt = nil
            }
            XCTAssertEqual(frame, rest, motion.rawValue)
            let ticks = Array(RoomTicks.of(track, from: start, spriteStart: SpritePlayer.aligned(start), plays: true, mode: .none))
            XCTAssertEqual(ticks, [start], "\(motion.rawValue): one draw, no timer")
        }
    }

    // A room that goes off screen in the middle of a motion is at rest
    // when the next state comes.
    func testOffScreenEndsARunningMotion() {
        var track = demo(.requestOut).track()
        track.set(RoomWorld(), pose: .work, at: at(100), mode: .none)
        XCTAssertNil(track.motionEnd)
        XCTAssertEqual(track.frame(at: at(100)), RoomMotionTrack(world: RoomWorld(), pose: .work).frame(at: at(100)))
    }

    // A room whose window hides in the middle of a motion settles: it
    // is at rest in its world. A frozen character keeps its pose.
    func testSettleEndsEveryMove() {
        var track = demo(.requestOut).track()
        track.settle()
        XCTAssertNil(track.motionEnd)
        XCTAssertEqual(track.frame(at: at(10)), demo(.requestOut).rest.frame(at: at(10)))
        var reduced = demo(.spawn).track(mode: .reduced)
        reduced.settle()
        XCTAssertNil(reduced.snapshot(at: at(10)).previous)
        var frozen = demo(.freeze).track()
        frozen.settle()
        XCTAssertEqual(frozen.frame(at: at(10)).pose, .work)
        XCTAssertEqual(frozen.frame(at: at(10)).frost, 1)
    }

    // The children of a run: the live runs whose parent it is.
    func testChildrenOfARun() {
        func room(_ id: String, parent: String? = nil, state: AgentState = .working) -> AgentRoom {
            AgentRoom(key: id, runID: id, paneID: nil, harness: "claude", title: "Claude Code", project: nil, branch: nil,
                      started: nil, ended: nil, state: state, requests: [], filesChanged: nil, files: nil, activity: nil,
                      network: nil, paneRunning: false, parent: parent)
        }
        let rooms = [room("a"), room("b", parent: "a"), room("c", parent: "a", state: .ended(done: true)), room("d", parent: "b")]
        XCTAssertEqual(AgentRooms.children(of: rooms[0], in: rooms), 1, "the ended child does not count")
        XCTAssertEqual(AgentRooms.children(of: rooms[1], in: rooms), 1)
        XCTAssertEqual(AgentRooms.children(of: rooms[3], in: rooms), 0)
        let listed = AgentRooms.of(runs: [AgentRunJSON(id: "a", harness: "claude"),
                                          AgentRunJSON(id: "b", harness: "codex", parent: "a")],
                                   ended: [], board: [:], requests: [], panes: [])
        XCTAssertEqual(listed.first { $0.runID == "b" }?.parent, "a")
        XCTAssertEqual(AgentRooms.children(of: listed.first { $0.runID == "a" }!, in: listed), 1)
        XCTAssertTrue(RoomWorld.of(listed.first { $0.runID == "a" }!, children: 1).child)
    }

    // MARK: Ticks

    // A motion draws 30 times a second and not more, its last tick is
    // its end, and then the sprite loop ticks 8 times a second on the
    // shared grid.
    func testTicksAreCappedAtThirtyASecond() {
        for motion in WorldMotion.allCases {
            guard let demo = MotionDemo.of(motion) else { continue }
            let track = demo.track()
            let end = demo.end()
            let sprite = SpritePlayer.aligned(start)
            var ticks: [Date] = []
            for tick in RoomTicks.of(track, from: start, spriteStart: sprite, plays: true, mode: .full) {
                if tick > end.addingTimeInterval(1) { break }
                ticks.append(tick)
            }
            XCTAssertEqual(ticks.first, start, motion.rawValue)
            XCTAssertTrue(ticks.contains(end), "\(motion.rawValue): the rest state is drawn")
            for (a, b) in zip(ticks, ticks.dropFirst()) {
                XCTAssertGreaterThan(b, a, motion.rawValue)
            }
            let during = ticks.filter { $0 <= end }
            // The length in whole milliseconds: a date has a coarser grain.
            let length = (end.timeIntervalSince(start) * 1000).rounded() / 1000
            let expected = Int((length * 30 - 1e-6).rounded(.up)) + 1
            XCTAssertEqual(during.count, expected, motion.rawValue)
            for (a, b) in zip(during, during.dropFirst()) where b < end {
                XCTAssertEqual(b.timeIntervalSince(a), 1.0 / 30, accuracy: 1e-6, motion.rawValue)
            }
            // In any second there are at most 30 ticks.
            for tick in ticks {
                let window = ticks.filter { $0 >= tick && $0 < tick.addingTimeInterval(1 - 1e-6) }
                XCTAssertLessThanOrEqual(window.count, 30, motion.rawValue)
            }
            // After the end: the grid of the sprite loops.
            let after = ticks.filter { $0 > end }
            XCTAssertEqual(after.count, 8, motion.rawValue)
            for tick in after {
                XCTAssertEqual(SpritePlayer.aligned(tick), tick, "\(motion.rawValue): on the shared grid")
            }
        }
    }

    // A room at rest with a loop ticks only on the sprite grid. A room
    // with no loop and no motion draws once.
    func testTicksOfARoomAtRest() {
        let rest = RoomMotionTrack(world: RoomWorld(), pose: .sleep)
        let sprite = SpritePlayer.aligned(start.addingTimeInterval(0.01))
        var playing = RoomTicks.of(rest, from: start.addingTimeInterval(0.01), spriteStart: sprite, plays: true, mode: .full)
        XCTAssertEqual(playing.next(), start.addingTimeInterval(0.01))
        XCTAssertEqual(playing.next(), sprite)
        XCTAssertEqual(playing.next(), sprite.addingTimeInterval(0.125))
        XCTAssertEqual(playing.next(), sprite.addingTimeInterval(0.25))

        XCTAssertEqual(Array(RoomTicks.of(rest, from: start, spriteStart: sprite, plays: false, mode: .full)), [start])
        XCTAssertEqual(Array(RoomTicks.of(rest, from: start, spriteStart: sprite, plays: true, mode: .reduced)), [start])

        // A glow breathes on the sprite grid even when the loop is still.
        let glowing = RoomMotionTrack(world: RoomWorld(changes: true), pose: .blocked)
        var breath = RoomTicks.of(glowing, from: start, spriteStart: start, plays: false, mode: .full)
        XCTAssertEqual(breath.next(), start)
        XCTAssertEqual(breath.next(), start.addingTimeInterval(0.125))
    }

    // With Reduce Motion the cross-fade ticks for 150 ms, and a ring
    // then ticks once a second: the time left is a fact, not a motion.
    func testTicksWithReduceMotion() {
        let track = demo(.requestOut).track(mode: .reduced)
        var ticks: [Date] = []
        for tick in RoomTicks.of(track, from: start, spriteStart: start, plays: false, mode: .reduced) {
            if tick > at(3200) { break }
            ticks.append(tick)
        }
        XCTAssertEqual(ticks.filter { $0 <= at(150) }.count, 6, "0, 33, 67, 100, 133 and 150 ms")
        XCTAssertTrue(ticks.contains(at(150)))
        XCTAssertEqual(ticks.filter { $0 > at(150) }, [at(1000), at(2000), at(3000)])

        let plain = demo(.network).track(mode: .reduced)
        let all = Array(RoomTicks.of(plain, from: start, spriteStart: start, plays: false, mode: .reduced))
        XCTAssertEqual(all.last, at(150))
        XCTAssertEqual(all.count, 6)
    }

    // MARK: Between views

    // The zoom from a card to the room of the detail: at the start the
    // room is at the place and the size of the card, at the end at its own.
    func testZoomFromACard() {
        let card = MotionRect(x: 40, y: 300, width: 176, height: 176)
        let room = MotionRect(x: 320, y: 60, width: 88, height: 88)
        let first = ZoomTransform.of(from: card, to: room, progress: 0)
        XCTAssertEqual(first.scale, 2)
        XCTAssertEqual(first.x, card.midX - room.midX)
        XCTAssertEqual(first.y, card.midY - room.midY)
        let middle = ZoomTransform.of(from: card, to: room, progress: 0.5)
        XCTAssertEqual(middle.scale, 1.5)
        XCTAssertEqual(middle.x, first.x / 2)
        XCTAssertEqual(ZoomTransform.of(from: card, to: room, progress: 1), .identity)
        XCTAssertEqual(ZoomTransform.of(from: MotionRect(x: 0, y: 0, width: 0, height: 0), to: room, progress: 0), .identity)
        XCTAssertEqual(ZoomTransform.plain(progress: 1), .identity)
        XCTAssertEqual(ZoomTransform.plain(progress: 0).scale, CardMotion.zoomFallbackScale)

        // The spring of the zoom: 450 ms, a little past the end, then rest.
        let zoom = WorldMotion.zoom
        XCTAssertEqual(zoom.progress(0), 0)
        XCTAssertEqual(zoom.progress(0.45), 1)
        XCTAssertGreaterThan(zoom.progress(0.225), 0.7, "a spring is fast at first")
        let most = (0...450).map { zoom.progress(Double($0) / 1000) }.max() ?? 0
        XCTAssertGreaterThan(most, 1)
        XCTAssertLessThan(most, 1.03, "a small overshoot")
    }

    // A card comes with a soft growth and a fade and leaves the same
    // way; the pointer lifts it a little.
    func testCardsComeAndGoSoftly() {
        XCTAssertEqual(CardMotion.entering(0).scale, CardMotion.enterScale)
        XCTAssertEqual(CardMotion.entering(0).opacity, 0)
        XCTAssertEqual(CardMotion.entering(1).scale, 1, accuracy: 1e-12)
        XCTAssertEqual(CardMotion.entering(1).opacity, 1)
        XCTAssertEqual(CardMotion.leaving(0).scale, 1)
        XCTAssertEqual(CardMotion.leaving(0).opacity, 1)
        XCTAssertEqual(CardMotion.leaving(1).scale, CardMotion.leaveScale, accuracy: 1e-12)
        XCTAssertEqual(CardMotion.leaving(1).opacity, 0)
        XCTAssertGreaterThanOrEqual(CardMotion.enterScale, 0.9, "soft: the card does not pop")
        XCTAssertEqual(CardMotion.hover(0).lift, 0)
        XCTAssertEqual(CardMotion.hover(1).lift, CardMotion.hoverLift)
        XCTAssertLessThanOrEqual(CardMotion.hoverLift, 3, "a slight lift")
        XCTAssertLessThanOrEqual(CardMotion.hoverScale, 1.02)
        XCTAssertEqual(CardMotion.hover(0).scale, 1)
    }

    // MARK: The snapshot switch

    // NAME@MS names a motion and a moment.
    func testFreezeParses() {
        XCTAssertEqual(MotionFreeze.parse("request-out@250"), MotionFreeze(motion: .requestOut, milliseconds: 250))
        XCTAssertEqual(MotionFreeze.parse(" Freeze@0 "), MotionFreeze(motion: .freeze, milliseconds: 0))
        XCTAssertEqual(MotionFreeze.parse("zoom@450")?.progress, 1)
        XCTAssertEqual(MotionFreeze.parse("zoom@0")?.progress, 0)
        for bad in ["", "request-out", "request-out@", "@250", "dance@250", "freeze@-1", "freeze@1.5", "freeze@250@1"] {
            XCTAssertNil(MotionFreeze.parse(bad), bad)
        }
        XCTAssertNil(MotionFreeze.parse(nil))
        for motion in WorldMotion.allCases {
            XCTAssertEqual(MotionFreeze.parse("\(motion.rawValue)@10")?.motion, motion)
        }
    }

    // A frozen frame is the frame of the demo at that moment, every time.
    func testFrozenFrames() throws {
        let freeze = try XCTUnwrap(MotionFreeze.parse("request-out@250"))
        let snapshot = try XCTUnwrap(freeze.snapshot())
        XCTAssertEqual(snapshot.frame, demo(.requestOut).track().frame(at: at(250)))
        XCTAssertEqual(snapshot.frame.walk, 0.5, accuracy: 1e-5)
        XCTAssertEqual(freeze.snapshot(), snapshot, "the same picture every time")
        XCTAssertNil(snapshot.previous)

        // With Reduce Motion: the cross-fade at that moment.
        let reduced = try XCTUnwrap(MotionFreeze(motion: .freeze, milliseconds: 75).snapshot(mode: .reduced))
        XCTAssertEqual(reduced.fade, 0.5, accuracy: 1e-5)
        XCTAssertEqual(reduced.frame.frost, 1)
        XCTAssertEqual(reduced.previous?.frost, 0)

        // Past the end: the rest state.
        let late = try XCTUnwrap(MotionFreeze(motion: .spawn, milliseconds: 5000).snapshot())
        XCTAssertEqual(late.frame, demo(.spawn).rest.frame(at: at(5000)))
        XCTAssertNil(MotionFreeze(motion: .zoom, milliseconds: 100).snapshot())
        XCTAssertEqual(MotionFreeze(motion: .cardEnter, milliseconds: 110).progress,
                       WorldMotion.cardEnter.curve.value(0.5), accuracy: 1e-12)
    }

    // MARK: The world of a room

    // The world of an app: the light follows the session, a suspended
    // session is frozen, a question sends the character to the door.
    func testWorldOfAnApp() {
        XCTAssertEqual(RoomWorld.of(app("a", state: "running"), questions: 0), RoomWorld(lit: true))
        XCTAssertEqual(RoomWorld.of(app("a", state: "starting"), questions: 0), RoomWorld(lit: true))
        XCTAssertEqual(RoomWorld.of(app("a", state: "stopped"), questions: 0), RoomWorld(lit: false))
        XCTAssertEqual(RoomWorld.of(app("a", state: "saved"), questions: 0), RoomWorld(lit: false))
        XCTAssertEqual(RoomWorld.of(app("a", state: "stopping"), questions: 0), RoomWorld(lit: false))
        XCTAssertEqual(RoomWorld.of(app("a", state: "suspended"), questions: 0), RoomWorld(lit: false, frozen: true))
        XCTAssertEqual(RoomWorld.of(app("a", state: "running"), questions: 2),
                       RoomWorld(lit: true, request: RoomWorld.Request()))
        XCTAssertNil(RoomWorld.of(app("a", state: "error"), questions: 2).request, "a failed app shows the failure")
        // A scene alone: dark when the character sleeps, nobody at the door.
        XCTAssertEqual(RoomWorld.of(RoomScene.empty), RoomWorld(lit: false))
        XCTAssertEqual(RoomWorld.of(RoomScene.welcome), RoomWorld(lit: true))
        XCTAssertEqual(RoomWorld.of(RoomScene(tint: .cream, color: .gray, pose: .wait, badge: 1)), RoomWorld(lit: true))
    }

    // The world of an agent run: the oldest request at the door with its
    // time, the network at the window, the glow of changed files.
    func testWorldOfAnAgent() {
        let created = ISO.date("2026-11-06T10:00:00Z")
        var room = AgentRoom(key: "run-1", runID: "run-1", paneID: nil, harness: "claude", title: "Claude Code",
                             project: "/Users/demo/src/shop", branch: nil, started: created, ended: nil, state: .working,
                             requests: [], filesChanged: 3, files: nil, activity: nil, network: "api", paneRunning: false)
        XCTAssertEqual(RoomWorld.of(room), RoomWorld(lit: true, network: .limited, changes: true))
        XCTAssertEqual(RoomWorld.of(room, children: 2).child, true)

        let late = AgentRequestJSON(id: "r2", sandbox: "run-1", capability: "exec", created: created.addingTimeInterval(60),
                                    expires: created.addingTimeInterval(660))
        let early = AgentRequestJSON(id: "r1", sandbox: "run-1", capability: "exec", created: created,
                                     expires: created.addingTimeInterval(600))
        room.state = .waiting(2)
        room.requests = [late, early]
        let world = RoomWorld.of(room)
        XCTAssertEqual(world.request, RoomWorld.Request(created: created, expires: created.addingTimeInterval(600)))
        XCTAssertEqual(world.request?.left(at: created.addingTimeInterval(150)), 0.75)

        room.state = .ended(done: true)
        room.requests = []
        let ended = RoomWorld.of(room)
        XCTAssertFalse(ended.lit)
        XCTAssertFalse(ended.changes, "an ended run has no copy that waits")

        XCTAssertEqual(RoomWorld.Network.of("none"), .closed)
        XCTAssertEqual(RoomWorld.Network.of("API"), .limited)
        XCTAssertEqual(RoomWorld.Network.of("egress"), .open)
        XCTAssertEqual(RoomWorld.Network.of("host"), .open)
        XCTAssertNil(RoomWorld.Network.of("mesh"))
        XCTAssertNil(RoomWorld.Network.of(nil))
    }

    func app(_ name: String, state: String) -> AppItem {
        var fields: [String: Any] = ["name": name, "state": state]
        if state == "error" { fields["reason"] = "The VM stopped" }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return AppItem(json: try! PaddockJSON.decoder.decode(AppJSON.self, from: data))
    }
}
