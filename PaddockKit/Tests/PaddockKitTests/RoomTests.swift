import Foundation
import XCTest
@testable import PaddockKit

/// The rooms of the library: the sprite of each state, the sprite clock
/// and Reduce Motion, the icon on the laptop screen from rooms.json, and
/// the arrow keys of the grid.
final class RoomTests: XCTestCase {
    // MARK: State to sprite

    func testPoseOfEachState() {
        let cases: [(AppState, CharacterPose)] = [
            (.running(since: nil, windows: 3), .work),
            (.stopped, .sleep),
            (.saved(since: nil), .sleep),
            (.suspended(reason: nil), .sleep),
            (.starting(.booting), .idle),
            (.stopping, .idle),
            (.error(reason: "The VM stopped"), .blocked),
            (.blocked(reason: "No base image", code: "no_golden"), .blocked),
        ]
        for (state, pose) in cases {
            XCTAssertEqual(RoomScene.pose(state, questions: 0), pose, "\(state)")
        }
    }

    // An open question makes the character wait; a failure still wins.
    func testQuestionsWaitUnlessFailed() {
        XCTAssertEqual(RoomScene.pose(.running(since: nil, windows: 1), questions: 2), .wait)
        XCTAssertEqual(RoomScene.pose(.starting(.opening), questions: 1), .wait)
        XCTAssertEqual(RoomScene.pose(.error(reason: "x"), questions: 3), .blocked)
        XCTAssertEqual(RoomScene.pose(.blocked(reason: "x", code: nil), questions: 3), .blocked)
    }

    func testSceneOfAnApp() {
        let running = app("sample-notes", state: "running", windows: 3)
        let waiting = RoomScene.of(running, index: 0, questions: 2)
        XCTAssertEqual(waiting.pose, .wait)
        XCTAssertEqual(waiting.badge, 2)
        XCTAssertFalse(waiting.showsProgress)
        XCTAssertEqual(waiting.tint, .cream)

        let working = RoomScene.of(running, index: 1, questions: 0)
        XCTAssertEqual(working.pose, .work)
        XCTAssertNil(working.badge, "no badge without a question")
        XCTAssertEqual(working.tint, .blue)

        let starting = RoomScene.of(app("sample-mail", state: "starting", phase: "booting"), index: 2, questions: 0)
        XCTAssertEqual(starting.pose, .idle)
        XCTAssertTrue(starting.showsProgress, "idle plus the progress while it starts")
        XCTAssertEqual(starting.tint, .lilac)

        let failed = RoomScene.of(app("sample-mail", state: "error", reason: "x"), index: 3, questions: 4)
        XCTAssertEqual(failed.pose, .blocked)
        XCTAssertNil(failed.badge)
        XCTAssertFalse(failed.showsProgress)
        XCTAssertEqual(failed.tint, .mint)
    }

    func testTintsRotate() {
        XCTAssertEqual((0..<9).map(RoomTint.at),
                       [.cream, .blue, .lilac, .mint, .cream, .blue, .lilac, .mint, .cream])
        XCTAssertEqual(RoomTint.at(-1), .mint)
    }

    // An app keeps its character across launches and instances; gray is
    // the onboarding's.
    func testCharacterColors() {
        XCTAssertEqual(CharacterColor.of(app: "sample-notes"), CharacterColor.of(app: "sample-notes"))
        for name in ["sample-notes", "sample-mail", "notebook", "", "x"] {
            XCTAssertNotEqual(CharacterColor.of(app: name), .gray, name)
        }
        let colors = Set(["a", "b", "c", "d", "e", "f", "g", "h", "sample-notes", "sample-mail"].map { CharacterColor.of(app: $0) })
        XCTAssertGreaterThan(colors.count, 1, "the names spread over the colors")
        XCTAssertEqual(RoomScene.welcome.color, .gray)
        let notes = app("sample-notes", state: "stopped")
        let second = app("sample-notes", state: "stopped", home: "instance-2")
        XCTAssertEqual(RoomScene.of(notes, index: 0, questions: 0).color, RoomScene.of(second, index: 1, questions: 0).color)
    }

    func testSpriteNames() {
        XCTAssertEqual(SpriteName.character(.blue, .work, frame: 1), "character-blue-work-1")
        XCTAssertEqual(SpriteName.character(.gray, .blocked, frame: 12), "character-gray-blocked-12")
        XCTAssertEqual(SpriteName.room(.lilac), "room-lilac")
        XCTAssertEqual(SpriteName.manifest, "rooms")
        XCTAssertEqual(CharacterPose.allCases.map(\.rawValue), ["work", "wait", "sleep", "idle", "blocked"])
    }

    func testQuestionCopy() {
        XCTAssertEqual(RoomCopy.questions(1).english, "1 question")
        XCTAssertEqual(RoomCopy.questions(3).english, "3 questions")
    }

    // MARK: Sprite clock

    func testSpritePlaysAtEightFramesASecond() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let player = SpritePlayer(frameCount: 4, start: start)
        let frames = [0, 0.124, 0.125, 0.25, 0.375, 0.5, 0.874, 1.0, 1.125].map {
            player.frame(at: start.addingTimeInterval($0), playing: true)
        }
        XCTAssertEqual(frames, [0, 0, 1, 2, 3, 0, 2, 0, 1])
        XCTAssertEqual(SpritePlayer.fps, 8)
        XCTAssertEqual(SpritePlayer.frameInterval, 0.125, accuracy: 1e-12)
        XCTAssertEqual(player.frame(at: start.addingTimeInterval(-5), playing: true), 0, "before the start")
        XCTAssertEqual(SpritePlayer(frameCount: 6, start: start).frame(at: start.addingTimeInterval(10), playing: true), 80 % 6)
    }

    // Reduce Motion, a hidden window or a room off screen: the first
    // frame, whatever the time.
    func testSpriteStopsOnFirstFrame() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let player = SpritePlayer(frameCount: 4, start: start)
        for t in [0.2, 0.3, 0.4, 7.7] {
            XCTAssertEqual(player.frame(at: start.addingTimeInterval(t), playing: false), 0)
        }
        XCTAssertTrue(SpritePlayer.isPlaying(windowVisible: true, onScreen: true, reduceMotion: false, frameCount: 4))
        XCTAssertFalse(SpritePlayer.isPlaying(windowVisible: true, onScreen: true, reduceMotion: true, frameCount: 4))
        XCTAssertFalse(SpritePlayer.isPlaying(windowVisible: false, onScreen: true, reduceMotion: false, frameCount: 4))
        XCTAssertFalse(SpritePlayer.isPlaying(windowVisible: true, onScreen: false, reduceMotion: false, frameCount: 4))
        XCTAssertFalse(SpritePlayer.isPlaying(windowVisible: true, onScreen: true, reduceMotion: false, frameCount: 1),
                       "one frame has nothing to play")
        XCTAssertEqual(SpritePlayer(frameCount: 1, start: start).frame(at: start.addingTimeInterval(3), playing: true), 0)
    }

    // MARK: rooms.json and the icon

    static let catalogManifest = Fixtures.root.deletingLastPathComponent()
        .appendingPathComponent("App/Assets.xcassets/Rooms/rooms.dataset/rooms.json")

    // The rooms.json of the asset catalog: every tint, each screen a
    // convex quad inside the room, the character inside the room.
    func testCatalogManifestIsValid() throws {
        let manifest = try RoomsManifest.decode(Data(contentsOf: RoomTests.catalogManifest))
        XCTAssertEqual(manifest.v, 1)
        XCTAssertGreaterThan(manifest.iconScale, 0)
        XCTAssertLessThanOrEqual(manifest.iconScale, 1)
        for tint in RoomTint.allCases {
            let room = try XCTUnwrap(manifest.rooms[tint.rawValue], tint.rawValue)
            for corner in room.screen.corners {
                XCTAssertTrue((0...manifest.roomSize).contains(corner.x) && (0...manifest.roomSize).contains(corner.y),
                              "\(tint): \(corner) outside the room")
            }
            XCTAssertTrue(RoomTests.isConvex(room.screen), "\(tint): the screen corners go round in order")
            let box = manifest.characterBox(tint)
            XCTAssertGreaterThan(box.size, 0)
            XCTAssertLessThanOrEqual(box.x + box.size, manifest.roomSize)
            XCTAssertLessThanOrEqual(box.y + box.size, manifest.roomSize)
        }
    }

    func testManifestRejectsOtherVersions() {
        let json = #"{"v": 2, "room_size": 512, "icon_scale": 0.8, "character": {"x": 0, "y": 0, "size": 10}, "rooms": {}}"#
        XCTAssertThrowsError(try RoomsManifest.decode(Data(json.utf8)))
        XCTAssertThrowsError(try RoomsManifest.decode(Data("not json".utf8)))
    }

    // A tint missing in the file borrows the first room there is.
    func testMissingTintBorrowsARoom() throws {
        let json = #"""
        {"v": 1, "room_size": 512, "icon_scale": 0.8, "character": {"x": 10, "y": 20, "size": 100},
         "rooms": {"blue": {"screen": {"top_left": [10, 10], "top_right": [50, 10], "bottom_right": [50, 40], "bottom_left": [10, 40]},
                            "character": {"x": 1, "y": 2, "size": 3}}}}
        """#
        let manifest = try RoomsManifest.decode(Data(json.utf8))
        XCTAssertEqual(manifest.room(.mint).screen.topRight, RoomPoint(x: 50, y: 10))
        XCTAssertEqual(manifest.characterBox(.blue), CharacterBox(x: 1, y: 2, size: 3), "a room's own box wins")
        let empty = RoomsManifest(v: 1, roomSize: 512, iconScale: 0.8, character: CharacterBox(x: 0, y: 0, size: 1), rooms: [:])
        XCTAssertEqual(empty.room(.cream), RoomsManifest.placeholder.rooms["cream"])
    }

    // The map of the unit square hits the four corners, also for a quad
    // in perspective.
    func testHomographyHitsTheCorners() {
        let quads = [
            ScreenQuad(topLeft: RoomPoint(x: 252, y: 226), topRight: RoomPoint(x: 324, y: 262),
                       bottomRight: RoomPoint(x: 324, y: 318), bottomLeft: RoomPoint(x: 252, y: 282)),
            ScreenQuad(topLeft: RoomPoint(x: 10, y: 20), topRight: RoomPoint(x: 90, y: 5),
                       bottomRight: RoomPoint(x: 100, y: 80), bottomLeft: RoomPoint(x: 0, y: 70)),
        ]
        let unit = [RoomPoint(x: 0, y: 0), RoomPoint(x: 1, y: 0), RoomPoint(x: 1, y: 1), RoomPoint(x: 0, y: 1)]
        for quad in quads {
            let map = Homography.unitSquare(to: quad)
            for (source, corner) in zip(unit, quad.corners) {
                assertClose(map.apply(source), corner)
            }
        }
        // A parallelogram needs no perspective.
        let flat = Homography.unitSquare(to: quads[0])
        XCTAssertEqual(flat.g, 0, accuracy: 1e-12)
        XCTAssertEqual(flat.h, 0, accuracy: 1e-12)
        XCTAssertNotEqual(Homography.unitSquare(to: quads[1]).g, 0)
    }

    // The icon: a square in the screen's plane, centered, its side
    // icon_scale of the shorter screen edge; the transform of the icon
    // view puts its corners there; a smaller room scales it all.
    func testIconPlacementFromRoomsJSON() throws {
        let manifest = try RoomsManifest.decode(Data(contentsOf: RoomTests.catalogManifest))
        for tint in RoomTint.allCases {
            let screen = manifest.room(tint).screen
            let quad = IconPlacement.iconQuad(manifest, tint: tint, side: manifest.roomSize)
            let top = IconPlacement.distance(quad.topLeft, quad.topRight)
            let left = IconPlacement.distance(quad.topLeft, quad.bottomLeft)
            let shorter = min(IconPlacement.distance(screen.topLeft, screen.topRight),
                              IconPlacement.distance(screen.topLeft, screen.bottomLeft))
            XCTAssertEqual(top, manifest.iconScale * shorter, accuracy: 1e-6, "\(tint)")
            XCTAssertEqual(left, manifest.iconScale * shorter, accuracy: 1e-6, "\(tint)")
            assertClose(RoomTests.center(quad), RoomTests.center(screen))
            for corner in quad.corners {
                XCTAssertTrue(RoomTests.inside(corner, screen), "\(tint): \(corner) off the screen")
            }
            // The icon view, 64 pt square at the room's top left.
            let map = IconPlacement.transform(manifest, tint: tint, side: manifest.roomSize, iconSide: 64)
            let view = [RoomPoint(x: 0, y: 0), RoomPoint(x: 64, y: 0), RoomPoint(x: 64, y: 64), RoomPoint(x: 0, y: 64)]
            for (source, corner) in zip(view, quad.corners) {
                assertClose(map.apply(source), corner)
            }
            // A card draws the room at 176 pt, the header at 160 pt.
            for side in [176.0, 160.0] {
                let small = IconPlacement.iconQuad(manifest, tint: tint, side: side)
                for (a, b) in zip(small.corners, quad.corners) {
                    assertClose(a, b.scaled(side / manifest.roomSize))
                }
            }
        }
    }

    func testCharacterBoxScales() {
        let box = IconPlacement.characterBox(.placeholder, tint: .cream, side: 256)
        XCTAssertEqual(box, CharacterBox(x: 30, y: 118, size: 100))
    }

    // MARK: The art

    static let launcher = Fixtures.root.deletingLastPathComponent()
    static let catalogRooms = launcher.appendingPathComponent("App/Assets.xcassets/Rooms")

    // The catalog has the art's rooms.json, unchanged.
    func testCatalogManifestIsTheArtFile() throws {
        let art = try Data(contentsOf: RoomTests.launcher.appendingPathComponent("Sprites/rooms.json"))
        XCTAssertEqual(try Data(contentsOf: RoomTests.catalogManifest), art)
        let file = try ArtRoomsFile.decode(art)
        XCTAssertEqual(file.size, [512, 512])
        XCTAssertNotNil(file.rooms[ArtRoomsFile.screenRoom]?.screen)
    }

    // The art's rooms.json in the launcher's terms: every tint takes the
    // screen and the character place of room-cream-screen.png, because
    // every room draws the front layer with the screen to the viewer.
    func testArtManifestGeometry() throws {
        let manifest = try RoomsManifest.decode(Data(contentsOf: RoomTests.catalogManifest))
        XCTAssertEqual(manifest.v, 1)
        XCTAssertEqual(manifest.roomSize, 512)
        XCTAssertEqual(manifest.iconScale, ArtRoomsFile.defaultIconScale)
        let screen = ScreenQuad(topLeft: RoomPoint(x: 224, y: 248.1), topRight: RoomPoint(x: 288, y: 248.1),
                                bottomRight: RoomPoint(x: 288, y: 287.2), bottomLeft: RoomPoint(x: 224, y: 287.2))
        for tint in RoomTint.allCases {
            XCTAssertEqual(manifest.room(tint).screen, screen, "\(tint)")
            let box = manifest.characterBox(tint)
            // The PNG at scale 0.512; its feet point (256, 135 + 150 / 0.512)
            // on the feet (191, 295).
            XCTAssertEqual(box.size, 512 * 0.512, accuracy: 1e-9)
            XCTAssertEqual(box.x, 191 - 256 * 0.512, accuracy: 1e-9)
            XCTAssertEqual(box.y, 295 - (135 * 0.512 + 150), accuracy: 1e-9)
        }
        // The character is 150 px high in the room, as rooms.json says.
        let box = manifest.characterBox(.cream)
        let antenna = box.y + CharacterArt.top * box.size / CharacterArt.side
        XCTAssertEqual(295 - antenna, 150, accuracy: 1e-9)
    }

    // The icon sits in the middle of the laptop screen of the art, as
    // high as the screen, in every tint and at every size.
    func testIconOnTheArtScreen() throws {
        let manifest = try RoomsManifest.decode(Data(contentsOf: RoomTests.catalogManifest))
        for tint in RoomTint.allCases {
            let quad = IconPlacement.iconQuad(manifest, tint: tint, side: 512)
            XCTAssertEqual(ArtRoomsFile.defaultIconScale, 1)
            let edge = ArtRoomsFile.defaultIconScale * (287.2 - 248.1)
            assertClose(quad.topLeft, RoomPoint(x: 256 - edge / 2, y: (248.1 + 287.2) / 2 - edge / 2))
            assertClose(quad.bottomRight, RoomPoint(x: 256 + edge / 2, y: (248.1 + 287.2) / 2 + edge / 2))
            let card = IconPlacement.iconQuad(manifest, tint: tint, side: 176)
            assertClose(card.topLeft, quad.topLeft.scaled(176.0 / 512))
        }
    }

    func testArtManifestNeedsAScreenRoom() {
        let noScreen = #"{"size": [512, 512], "rooms": {"room-cream.png": {"character": {"spriteScale": 0.5, "feet": [256, 298], "heightPx": 150}}}}"#
        XCTAssertThrowsError(try RoomsManifest.decode(Data(noScreen.utf8)))
        let notSquare = #"{"size": [512, 256], "rooms": {}}"#
        XCTAssertThrowsError(try RoomsManifest.decode(Data(notSquare.utf8)))
        let threeCorners = #"""
        {"size": [512, 512], "rooms": {"room-x.png": {"screen": {"corners": [[0, 0], [1, 0], [1, 1]]},
         "character": {"spriteScale": 0.5, "feet": [256, 298], "heightPx": 150}}}}
        """#
        XCTAssertThrowsError(try RoomsManifest.decode(Data(threeCorners.utf8)))
        // Another screen room and an own icon scale.
        let other = #"""
        {"size": [256, 256], "icon_scale": 0.5, "rooms": {"room-x.png": {"screen": {"corners": [[10, 10], [50, 10], [50, 40], [10, 40]]},
         "character": {"spriteScale": 0.25, "feet": [100, 200], "heightPx": 75}}}}
        """#
        let manifest = try? RoomsManifest.decode(Data(other.utf8))
        XCTAssertEqual(manifest?.roomSize, 256)
        XCTAssertEqual(manifest?.iconScale, 0.5)
        XCTAssertEqual(manifest?.room(.lilac).screen.bottomRight, RoomPoint(x: 50, y: 40))
    }

    // Room, character, front layer: the character sits behind the desk
    // and the laptop; the icon lies on the laptop screen of the front
    // layer; the badge and the progress stay on top.
    func testDrawOrder() {
        let order = RoomLayer.drawOrder
        XCTAssertEqual(order, [.room, .character, .front, .icon, .badge, .progress])
        XCTAssertEqual(Set(order), Set(RoomLayer.allCases), "every layer once")
        XCTAssertEqual(order.count, RoomLayer.allCases.count)
        func at(_ layer: RoomLayer) -> Int { order.firstIndex(of: layer)! }
        XCTAssertLessThan(at(.room), at(.character))
        XCTAssertLessThan(at(.character), at(.front))
        XCTAssertLessThan(at(.front), at(.icon))
        XCTAssertLessThan(at(.icon), at(.badge))
    }

    // A room draws the loop of each pose, the work loop too: a running
    // app types at its desk. The laptop of the work loop is cut at the
    // underside of the desk.
    func testRoomLoops() {
        for pose in CharacterPose.allCases {
            XCTAssertEqual(pose.roomSprite, pose)
        }
        XCTAssertEqual(CharacterPose.roomSprites, [.work, .wait, .sleep, .idle, .blocked])
        XCTAssertEqual(CharacterPose.allCases.map(\.frameCount), [8, 8, 4, 8, 4])
        XCTAssertEqual(RoomScene.welcome.pose.roomSprite, .work)
        XCTAssertEqual(CharacterArt.workFloor * 512, 326, accuracy: 1e-9)
        // The feet of the character stand above the cut, the desk legs end below it.
        XCTAssertGreaterThan(CharacterArt.workFloor * 512, 295)
        XCTAssertLessThan(CharacterArt.workFloor * 512, 355)
    }

    // A running app works while it has a window; with none yet it is
    // awake at its desk, as while it starts.
    func testRunningWorksWhileItHasWindows() {
        XCTAssertEqual(RoomScene.pose(.running(since: nil, windows: 1), questions: 0), .work)
        XCTAssertEqual(RoomScene.pose(.running(since: nil, windows: 0), questions: 0), .idle)
        XCTAssertEqual(RoomScene.pose(.starting(.booting), questions: 0), .idle)
        XCTAssertEqual(RoomScene.pose(.running(since: nil, windows: 0), questions: 1), .wait)
    }

    // Every name a room can ask for, once: 4 rooms, the front layer and
    // 7 colors x 32 frames.
    func testRoomImageNames() {
        let names = SpriteName.roomImages
        XCTAssertEqual(names.count, 4 + 1 + 7 * 32)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains("room-front-screen"))
        XCTAssertTrue(names.contains("character-teal-blocked-4"))
        XCTAssertFalse(names.contains("character-teal-blocked-5"))
        XCTAssertTrue(names.contains("character-orange-work-8"))
        XCTAssertFalse(names.contains("character-orange-work-9"))
        XCTAssertEqual(CharacterColor.allCases.map(\.rawValue), ["gray", "orange", "blue", "purple", "green", "pink", "teal"])
    }

    // The source catalog has an image set with its PNG for every name a
    // room asks for, and each loop ends where the art ends.
    func testCatalogFolderHasEveryRoomImage() throws {
        let files = FileManager.default
        for name in SpriteName.roomImages {
            let folder = RoomTests.catalogRooms.appendingPathComponent(name + ".imageset")
            let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("Contents.json")))
            let images = try XCTUnwrap((contents as? [String: Any])?["images"] as? [[String: Any]], name)
            let filenames = images.compactMap { $0["filename"] as? String }
            XCTAssertEqual(filenames, [name + ".png"], name)
            XCTAssertTrue(files.fileExists(atPath: folder.appendingPathComponent(name + ".png").path), name)
        }
        for color in CharacterColor.allCases {
            for pose in CharacterPose.allCases {
                let after = SpriteName.character(color, pose, frame: pose.frameCount + 1)
                XCTAssertFalse(files.fileExists(atPath: RoomTests.catalogRooms.appendingPathComponent(after + ".imageset").path),
                               "\(after): the loop is longer than the art")
            }
        }
    }

    // The art adds less than 6 MB to the app: the PNGs are compressed.
    func testCatalogArtSize() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: RoomTests.catalogRooms.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertGreaterThanOrEqual(files.count, SpriteName.roomImages.count)
        var bytes = 0
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: RoomTests.catalogRooms.appendingPathComponent(file).path)
            bytes += (attributes[.size] as? Int) ?? 0
            // A PNG of 512 x 512 px: the IHDR width and height.
            let head = try Data(contentsOf: RoomTests.catalogRooms.appendingPathComponent(file)).prefix(24)
            XCTAssertEqual(Array(head[16..<24]), [0, 0, 2, 0, 0, 0, 2, 0], file)
        }
        XCTAssertLessThan(bytes, 6_000_000)
    }

    // MARK: Grid keys

    func testColumnsFit() {
        XCTAssertEqual(RoomGridNavigation.columns(width: 0, cardWidth: 220, spacing: 16), 1)
        XCTAssertEqual(RoomGridNavigation.columns(width: 219, cardWidth: 220, spacing: 16), 1)
        XCTAssertEqual(RoomGridNavigation.columns(width: 456, cardWidth: 220, spacing: 16), 2)
        XCTAssertEqual(RoomGridNavigation.columns(width: 455, cardWidth: 220, spacing: 16), 1)
        XCTAssertEqual(RoomGridNavigation.columns(width: 700, cardWidth: 220, spacing: 16), 3)
    }

    // Seven cards in three columns:
    //   0 1 2
    //   3 4 5
    //   6
    func testArrowKeysMoveLikeFinder() {
        func move(_ index: Int?, _ key: RoomGridNavigation.Move) -> Int? {
            RoomGridNavigation.move(index, key, count: 7, columns: 3)
        }
        XCTAssertEqual(move(nil, .right), 0, "the first key selects the first card")
        XCTAssertEqual(move(0, .left), 0, "stops at the edge")
        XCTAssertEqual(move(0, .right), 1)
        XCTAssertEqual(move(2, .right), 3, "right wraps to the next row, as Finder")
        XCTAssertEqual(move(3, .left), 2)
        XCTAssertEqual(move(6, .right), 6)
        XCTAssertEqual(move(1, .down), 4)
        XCTAssertEqual(move(4, .down), 6, "into the shorter last row: the last card")
        XCTAssertEqual(move(6, .down), 6)
        XCTAssertEqual(move(6, .up), 3)
        XCTAssertEqual(move(1, .up), 1)
        XCTAssertEqual(move(9, .up), 0, "a stale index starts over")
        XCTAssertNil(RoomGridNavigation.move(0, .down, count: 0, columns: 3))
        XCTAssertEqual(RoomGridNavigation.move(0, .down, count: 3, columns: 0), 1, "at least one column")
    }

    // MARK: Helpers

    func app(_ name: String, state: String, phase: String? = nil, windows: Int? = nil, reason: String? = nil,
             home: String? = nil) -> AppItem {
        var fields: [String: Any] = ["name": name, "state": state]
        if let phase { fields["phase"] = phase }
        if let windows { fields["windows"] = windows }
        if let reason { fields["reason"] = reason }
        if let home { fields["home"] = home }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return AppItem(json: try! PaddockJSON.decoder.decode(AppJSON.self, from: data))
    }

    func assertClose(_ a: RoomPoint, _ b: RoomPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-6, file: file, line: line)
    }

    static func center(_ quad: ScreenQuad) -> RoomPoint {
        let c = quad.corners
        return RoomPoint(x: c.map(\.x).reduce(0, +) / 4, y: c.map(\.y).reduce(0, +) / 4)
    }

    static func cross(_ o: RoomPoint, _ a: RoomPoint, _ b: RoomPoint) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    static func isConvex(_ quad: ScreenQuad) -> Bool {
        let c = quad.corners
        let turns = (0..<4).map { cross(c[$0], c[($0 + 1) % 4], c[($0 + 2) % 4]) }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }

    static func inside(_ p: RoomPoint, _ quad: ScreenQuad) -> Bool {
        let c = quad.corners
        let sides = (0..<4).map { cross(c[$0], c[($0 + 1) % 4], p) }
        return sides.allSatisfy { $0 >= -1e-9 } || sides.allSatisfy { $0 <= 1e-9 }
    }
}
