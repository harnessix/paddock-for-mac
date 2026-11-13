import AppKit
import PaddockKit
import SwiftUI
import XCTest
@testable import PaddockLauncher

/// The app side of the rooms: the asset loader and its placeholders, the
/// rooms.json of the asset catalog, the icon transform SwiftUI gets, the
/// spoken line of a card, the kept List / Rooms choice and the snapshot
/// switch.
@MainActor
final class RoomAppChecks: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AppTests
        .deletingLastPathComponent() // launcher

    // No PNG yet: each loop is four marked placeholder frames, each room
    // its placeholder.
    func testPlaceholdersWithoutArt() {
        let loader = RoomArtLoader(lookup: { _ in nil }, manifestData: { nil })
        for color in CharacterColor.allCases {
            for pose in CharacterPose.allCases {
                let frames = loader.character(color, pose)
                XCTAssertEqual(frames, (0..<4).map { SpriteFrame.placeholderCharacter(color, pose, index: $0) }, "\(color) \(pose)")
                XCTAssertTrue(frames.allSatisfy(\.isPlaceholder))
            }
        }
        for tint in RoomTint.allCases {
            XCTAssertEqual(loader.room(tint), .placeholderRoom(tint))
        }
        XCTAssertEqual(loader.manifest, .placeholder)
        XCTAssertFalse(loader.manifestFromCatalog)
    }

    // PNGs replace the placeholders behind the same API: frames from 1 up
    // to the first gap, looked up once.
    func testArtReplacesPlaceholders() {
        var asked: [String] = []
        let image = NSImage(size: NSSize(width: 4, height: 4))
        let present: Set<String> = ["character-blue-work-1", "character-blue-work-2", "character-blue-work-3",
                                    "character-blue-work-5", "room-mint"]
        let loader = RoomArtLoader(lookup: { name in
            asked.append(name)
            return present.contains(name) ? image : nil
        }, manifestData: { nil })
        let frames = loader.character(.blue, .work)
        XCTAssertEqual(frames.count, 3, "frame 4 is missing: the loop ends at 3")
        XCTAssertFalse(frames.contains(where: \.isPlaceholder))
        XCTAssertEqual(asked, ["character-blue-work-1", "character-blue-work-2", "character-blue-work-3", "character-blue-work-4"])
        _ = loader.character(.blue, .work)
        XCTAssertEqual(asked.count, 4, "the second call reads the cache")
        XCTAssertTrue(loader.character(.blue, .sleep).allSatisfy(\.isPlaceholder), "a missing loop keeps its placeholder")
        XCTAssertEqual(loader.room(.mint), .image(image))
        XCTAssertEqual(loader.room(.cream), .placeholderRoom(.cream))
    }

    // The built app has rooms.json in its asset catalog, the same file as
    // in the source folder.
    func testCatalogHasRoomsJSON() throws {
        let asset = try XCTUnwrap(NSDataAsset(name: SpriteName.manifest), "no data asset Rooms/rooms")
        let file = try Data(contentsOf: RoomAppChecks.root.appendingPathComponent("App/Assets.xcassets/Rooms/rooms.dataset/rooms.json"))
        XCTAssertEqual(try RoomsManifest.decode(asset.data), try RoomsManifest.decode(file))
        XCTAssertTrue(RoomArtLoader.shared.manifestFromCatalog)
        XCTAssertEqual(RoomArtLoader.shared.manifest, try RoomsManifest.decode(file))
    }

    // The built app finds every image a room can ask for in its asset
    // catalog, by the names the loader uses; each loop has the frames of
    // the art and ends there.
    func testCatalogHasEveryRoomImage() {
        for name in SpriteName.roomImages {
            XCTAssertNotNil(NSImage(named: name), "no image set Rooms/\(name)")
        }
        for color in CharacterColor.allCases {
            for pose in CharacterPose.roomSprites {
                XCTAssertNil(NSImage(named: SpriteName.character(color, pose, frame: pose.frameCount + 1)),
                             "\(color) \(pose) has more frames than the art")
            }
        }
    }

    // The shared loader draws the real art: no placeholder, the frame
    // counts of the art, the PNGs drawn down to the pixels a room needs.
    func testSharedLoaderHasTheArt() throws {
        let art = RoomArtLoader.shared
        for tint in RoomTint.allCases {
            XCTAssertFalse(art.room(tint).isPlaceholder, "\(tint)")
        }
        XCTAssertFalse(art.front().isPlaceholder)
        for color in CharacterColor.allCases {
            for pose in CharacterPose.roomSprites {
                let frames = art.character(color, pose)
                XCTAssertEqual(frames.count, pose.frameCount, "\(color) \(pose)")
                XCTAssertFalse(frames.contains(where: \.isPlaceholder), "\(color) \(pose)")
            }
        }
        guard case .image(let image) = art.character(.orange, .idle)[0] else { return XCTFail("no image") }
        XCTAssertEqual(image.size, NSSize(width: 256, height: 256), "the 512 px PNG is the 2x of 256 pt")
        var rect = CGRect(origin: .zero, size: image.size)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        XCTAssertEqual(pixels.width, RoomArtLoader.characterPixels)
        XCTAssertTrue(art.loggedMissing.subtracting([SpriteName.manifest]).isEmpty, "\(art.loggedMissing)")
    }

    // A 512 px image drawn down keeps its point size and its picture.
    func testDownsampleKeepsThePicture() throws {
        let big = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: rect.height / 2).fill()
            return true
        }
        let small = try XCTUnwrap(RoomArtLoader.downsampled(big, pixels: 128))
        XCTAssertEqual(small.size, big.size)
        var rect = CGRect(origin: .zero, size: small.size)
        let cgImage = try XCTUnwrap(small.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        XCTAssertEqual(cgImage.width, 128)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        XCTAssertGreaterThan(bitmap.colorAt(x: 64, y: 120)?.alphaComponent ?? 0, 0.9, "the red bottom half stays at the bottom")
        XCTAssertLessThan(bitmap.colorAt(x: 64, y: 8)?.alphaComponent ?? 1, 0.1, "the top half stays clear")
    }

    // A room on screen holds its art; when the last room that holds it
    // leaves the screen, the frames go, and the next room loads them again.
    func testArtIsReleasedOffScreen() {
        var asked = 0
        let image = NSImage(size: NSSize(width: 4, height: 4))
        let loader = RoomArtLoader(lookup: { _ in asked += 1; return image }, manifestData: { nil })
        let scene = RoomScene(tint: .blue, color: .teal, pose: .work)
        let keys = RoomArtLoader.keys(scene)
        XCTAssertEqual(keys, [.room(.blue), .character(.teal, .work), .front], "a working room holds the work loop")
        _ = loader.room(.blue)
        _ = loader.front()
        _ = loader.character(.teal, .work)
        loader.hold(keys)
        loader.hold(keys)
        loader.release(keys)
        XCTAssertTrue(keys.allSatisfy(loader.isLoaded), "a second room still holds the art")
        XCTAssertEqual(loader.holderCount(.front), 1)
        loader.release(keys)
        XCTAssertFalse(keys.contains(where: loader.isLoaded), "no room holds it: released")
        XCTAssertEqual(loader.holderCount(.front), 0)
        loader.release(keys)
        XCTAssertEqual(loader.holderCount(.front), 0, "a release too many does nothing")
        let before = asked
        _ = loader.room(.blue)
        XCTAssertEqual(asked, before + 1, "loaded again")
    }

    // A missing image draws its placeholder and logs one line, also when
    // it is asked for again after a release.
    func testMissingArtLogsOnce() {
        let loader = RoomArtLoader(lookup: { _ in nil }, manifestData: { nil })
        XCTAssertEqual(loader.front(), .placeholderFront)
        XCTAssertEqual(loader.room(.lilac), .placeholderRoom(.lilac))
        _ = loader.character(.purple, .sleep)
        loader.hold([.room(.lilac)])
        loader.release([.room(.lilac)])
        XCTAssertEqual(loader.room(.lilac), .placeholderRoom(.lilac))
        XCTAssertEqual(loader.loggedMissing, [SpriteName.manifest, SpriteName.front, "room-lilac", "character-purple-sleep-1"])
    }

    func testBrokenRoomsJSONFallsBack() {
        let loader = RoomArtLoader(lookup: { _ in nil }, manifestData: { Data("{".utf8) })
        XCTAssertEqual(loader.manifest, .placeholder)
        XCTAssertFalse(loader.manifestFromCatalog)
    }

    // SwiftUI multiplies row vectors. The matrix the room gives
    // `projectionEffect` puts the icon view's corners on the icon quad.
    func testProjectionPutsTheIconOnTheScreen() {
        let manifest = RoomArtLoader.shared.manifest
        for side in [RoomSize.card, RoomSize.header, RoomSize.welcome] {
            let m = RoomView.projection(manifest, tint: .lilac, side: side)
            let quad = IconPlacement.iconQuad(manifest, tint: .lilac, side: Double(side))
            let s = RoomView.iconSide
            let view = [CGPoint(x: 0, y: 0), CGPoint(x: s, y: 0), CGPoint(x: s, y: s), CGPoint(x: 0, y: s)]
            for (p, corner) in zip(view, quad.corners) {
                let w = m.m13 * p.x + m.m23 * p.y + m.m33
                let x = (m.m11 * p.x + m.m21 * p.y + m.m31) / w
                let y = (m.m12 * p.x + m.m22 * p.y + m.m32) / w
                XCTAssertEqual(Double(x), corner.x, accuracy: 1e-6)
                XCTAssertEqual(Double(y), corner.y, accuracy: 1e-6)
            }
        }
    }

    // A room draws, placeholders included, at every size it is used.
    func testRoomRenders() throws {
        for (scene, side) in [(RoomScene.welcome, RoomSize.welcome),
                              (RoomScene(tint: .blue, color: .orange, pose: .wait, badge: 3), RoomSize.card),
                              (RoomScene(tint: .mint, color: .pink, pose: .idle, showsProgress: true), RoomSize.header)] {
            let renderer = ImageRenderer(content: RoomView(scene: scene, icon: .app(path: "/nonexistent/Gone.app"), side: side))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(scene)")
            XCTAssertEqual(image.width, Int(side * 2))
            XCTAssertEqual(image.height, Int(side * 2))
        }
    }

    func testSizes() {
        XCTAssertEqual(RoomSize.header, 160)
        XCTAssertEqual(RoomSize.cardWidth, RoomSize.card + 2 * RoomSize.cardPadding)
    }

    // `Sample Notes, Running, 3 windows`, then the questions.
    func testCardSpeech() throws {
        let app = try RoomAppChecks.app(#"{"name": "sample-notes", "display_name": "Sample Notes", "state": "running", "windows": 3}"#)
        let presentation = StatusPresentation.of(app.state, now: Date())
        XCTAssertEqual(RoomSpeech.of(app, presentation, questions: 0), "Sample Notes, Running, 3 windows")
        XCTAssertEqual(RoomSpeech.of(app, presentation, questions: 1), "Sample Notes, Running, 3 windows, 1 question")
        XCTAssertEqual(RoomSpeech.of(app, presentation, questions: 2), "Sample Notes, Running, 3 windows, 2 questions")
        let stopped = try RoomAppChecks.app(#"{"name": "sample-notes", "home": "instance-2", "display_name": "Sample Notes", "state": "stopped"}"#)
        XCTAssertEqual(RoomSpeech.of(stopped, .of(stopped.state, now: Date()), questions: 0), "Sample Notes 2, Stopped")
    }

    // The rooms follow the sidebar order: instances after their first one.
    func testRoomOrderAndTints() throws {
        let apps = try [
            RoomAppChecks.app(#"{"name": "sample-notes", "state": "running"}"#),
            RoomAppChecks.app(#"{"name": "sample-mail", "state": "stopped"}"#),
            RoomAppChecks.app(#"{"name": "sample-notes", "home": "instance-2", "state": "stopped"}"#),
        ]
        XCTAssertEqual(LibraryOrder.items(apps).map(\.key), ["sample-notes", "sample-notes--2", "sample-mail"])
        XCTAssertEqual(LibraryOrder.index(of: "sample-mail", in: apps), 2)
        XCTAssertEqual(RoomTint.at(LibraryOrder.index(of: "sample-mail", in: apps)), .lilac)
    }

    // The List / Rooms choice is kept for the next launch; a snapshot
    // does not change it.
    func testLayoutChoiceIsKept() {
        let defaults = LauncherDefaults.store
        let before = defaults.object(forKey: SettingsKey.libraryLayout)
        defer { defaults.set(before, forKey: SettingsKey.libraryLayout) }
        defaults.removeObject(forKey: SettingsKey.libraryLayout)
        XCTAssertEqual(UIRouter.savedLayout(), .list, "List until the user picks Rooms")
        let router = UIRouter()
        XCTAssertEqual(router.libraryLayout, .list)
        router.setLibraryLayout(.rooms)
        XCTAssertEqual(router.libraryLayout, .rooms)
        XCTAssertEqual(defaults.string(forKey: SettingsKey.libraryLayout), "rooms")
        XCTAssertEqual(UIRouter().libraryLayout, .rooms, "a new window starts at the last choice")
        router.libraryLayout = .list
        XCTAssertEqual(UIRouter.savedLayout(), .rooms, "only setLibraryLayout saves")
        defaults.set("tiles", forKey: SettingsKey.libraryLayout)
        XCTAssertEqual(UIRouter.savedLayout(), .list, "an unknown value is List")
    }

    func testSnapshotRoomsSwitch() {
        XCTAssertTrue(SnapshotDump.showsRooms(["PADDOCK_LAUNCHER_SNAPSHOT_ROOMS": "1"]))
        XCTAssertTrue(SnapshotDump.showsRooms(["PADDOCK_LAUNCHER_SNAPSHOT_ROOMS": "YES"]))
        XCTAssertFalse(SnapshotDump.showsRooms(["PADDOCK_LAUNCHER_SNAPSHOT_ROOMS": "0"]))
        XCTAssertFalse(SnapshotDump.showsRooms([:]))
    }

    func testTextsThroughTheCatalog() {
        XCTAssertEqual(RoomCopy.questions(2).localized, "2 questions")
        XCTAssertEqual(RoomCopy.questions(1).localized, "1 question")
        XCTAssertEqual(UIText("Placeholder art").localized, "Placeholder art")
    }

    static func app(_ json: String) throws -> AppItem {
        AppItem(json: try PaddockJSON.decoder.decode(AppJSON.self, from: Data(json.utf8)))
    }
}
