import AppKit
import PaddockKit
import SwiftUI
import XCTest
@testable import PaddockLauncher

/// The visual system: the spacing steps, the motion and Reduce Motion, the
/// look of a room card, the stage colors in each appearance, and the art
/// the rooms grid holds.
@MainActor
final class DesignChecks: XCTestCase {
    // MARK: Spacing

    // One scale: steps of 4 pt, each larger than the one before.
    func testSpacingScale() {
        XCTAssertEqual(Space.all, [4, 8, 12, 16, 20, 24])
        for step in Space.all {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 4), 0, "\(step)")
        }
        XCTAssertEqual(Space.all, Space.all.sorted())
        XCTAssertEqual(Space.page, 20, "the margin of a grouped form")
        XCTAssertEqual(RoomCardLook.stageSide(cardWidth: RoomSize.cardWidth), RoomSize.card)
        XCTAssertGreaterThan(RoomSize.maxCardWidth, RoomSize.cardWidth)
        XCTAssertEqual(RoomsGrid.margin, Space.page)
        XCTAssertEqual(RoomsGrid.spacing, Space.l)
        XCTAssertEqual(RoomCard.corner, Radius.card)
    }

    // MARK: Motion

    // Short and eased; nothing with Reduce Motion, nothing in a UI test.
    func testMotionIsShortAndStopsWithReduceMotion() {
        XCTAssertEqual(Motion.hover(false, still: false), Animation.easeOut(duration: Motion.quick))
        XCTAssertEqual(Motion.change(false, still: false), Animation.easeInOut(duration: Motion.standard))
        XCTAssertNil(Motion.hover(true, still: false))
        XCTAssertNil(Motion.change(true, still: false))
        XCTAssertNil(Motion.hover(false, still: true))
        XCTAssertNil(Motion.change(false, still: true))
        XCTAssertLessThanOrEqual(Motion.quick, 0.15)
        XCTAssertLessThanOrEqual(Motion.standard, 0.25)
        XCTAssertLessThan(Motion.quick, Motion.standard)
    }

    // The scheme sets PADDOCK_LAUNCHER_UITEST: a test run has no motion.
    func testTestRunsAreStill() {
        let flag = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_UITEST"] == "1"
        XCTAssertEqual(Motion.still, flag)
        if flag {
            XCTAssertNil(Motion.hover(false))
            XCTAssertNil(Motion.change(false))
        }
    }

    // The status dot pulses only while the app starts, the window is
    // visible and Reduce Motion is off.
    func testPulseStopsWhileHidden() {
        let now = Date()
        let starting = StatusPresentation.of(.starting(.booting), now: now)
        let running = StatusPresentation.of(.running(since: nil, windows: 1), now: now)
        XCTAssertTrue(StatusMotion.pulses(starting, reduceMotion: false, windowVisible: true))
        XCTAssertFalse(StatusMotion.pulses(starting, reduceMotion: false, windowVisible: false), "hidden window")
        XCTAssertFalse(StatusMotion.pulses(starting, reduceMotion: true, windowVisible: true), "Reduce Motion")
        XCTAssertFalse(StatusMotion.pulses(running, reduceMotion: false, windowVisible: true))
    }

    // MARK: Room card

    // The selection is easy to see: a wider ring than the hairline and a
    // wash; strongest while the grid has the keys; wider again with
    // Increase Contrast.
    func testCardSelectionIsEasyToSee() {
        let plain = RoomCardLook.ringWidth(selected: false, emphasized: false, increasedContrast: false)
        let quiet = RoomCardLook.ringWidth(selected: true, emphasized: false, increasedContrast: false)
        let strong = RoomCardLook.ringWidth(selected: true, emphasized: true, increasedContrast: false)
        XCTAssertEqual(plain, 1)
        XCTAssertGreaterThan(quiet, plain)
        XCTAssertGreaterThan(strong, quiet)
        XCTAssertEqual(strong, 3)
        for selected in [false, true] {
            for emphasized in [false, true] {
                XCTAssertGreaterThan(RoomCardLook.ringWidth(selected: selected, emphasized: emphasized, increasedContrast: true),
                                     RoomCardLook.ringWidth(selected: selected, emphasized: emphasized, increasedContrast: false))
            }
        }
        XCTAssertEqual(RoomCardLook.ring(selected: true, emphasized: true), Color.accentColor)
        XCTAssertNotEqual(RoomCardLook.ring(selected: true, emphasized: false), Color.accentColor)
        XCTAssertNotEqual(RoomCardLook.ring(selected: true, emphasized: false), RoomCardLook.ring(selected: false, emphasized: false))
        XCTAssertEqual(RoomCardLook.washOpacity(selected: false, emphasized: true), 0)
        XCTAssertGreaterThan(RoomCardLook.washOpacity(selected: true, emphasized: false), 0)
        XCTAssertGreaterThan(RoomCardLook.washOpacity(selected: true, emphasized: true),
                             RoomCardLook.washOpacity(selected: true, emphasized: false))
        XCTAssertLessThanOrEqual(RoomCardLook.washOpacity(selected: true, emphasized: true), 0.15, "the name stays readable")
    }

    func testCardHover() {
        XCTAssertEqual(RoomCardLook.veilOpacity(hovering: false), 0)
        XCTAssertGreaterThan(RoomCardLook.veilOpacity(hovering: true), 0)
        XCTAssertLessThanOrEqual(RoomCardLook.veilOpacity(hovering: true), 0.06, "the name stays readable")
        XCTAssertGreaterThan(RoomCardLook.shadowOpacity(hovering: true), RoomCardLook.shadowOpacity(hovering: false))
        XCTAssertGreaterThan(RoomCardLook.shadowRadius(hovering: true), RoomCardLook.shadowRadius(hovering: false))
    }

    // MARK: Stage

    /// `color` as sRGB parts, resolved in the appearance `name`.
    func rgb(_ color: NSColor, in name: NSAppearance.Name) throws -> RGB {
        let appearance = try XCTUnwrap(NSAppearance(named: name), name.rawValue)
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(resolved, name.rawValue)
        return RGB(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    /// The color AppKit gives for `tint` in the appearance `name`, with
    /// Increase Contrast on or off. The contrast is passed in: an
    /// appearance does not say it.
    func stage(_ tint: RoomTint, _ name: NSAppearance.Name, highContrast: Bool) throws -> RGB {
        try rgb(RoomStage.nsColor(tint, highContrast: highContrast), in: name)
    }

    /// The color a SwiftUI view gets for `tint` from its environment.
    func fill(_ tint: RoomTint, _ scheme: ColorScheme, _ contrast: ColorSchemeContrast) throws -> RGB {
        try rgb(NSColor(RoomStage.fill(tint, scheme: scheme, contrast: contrast)), in: .aqua)
    }

    func assertClose(_ a: RGB, _ b: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.01, message, file: file, line: line)
    }

    // The stage follows Dark Mode and Increase Contrast, and the outline
    // of the art reads on what AppKit really draws. Every tint passes the
    // bar of "dark, more contrast".
    func testStageFollowsTheAppearance() throws {
        for tint in RoomTint.allCases {
            let light = try stage(tint, .aqua, highContrast: false)
            let dark = try stage(tint, .darkAqua, highContrast: false)
            let lightHigh = try stage(tint, .aqua, highContrast: true)
            let darkHigh = try stage(tint, .darkAqua, highContrast: true)
            assertClose(light, RoomStage.color(tint, dark: false, highContrast: false), "\(tint) light")
            assertClose(dark, RoomStage.color(tint, dark: true, highContrast: false), "\(tint) dark")
            assertClose(lightHigh, RoomStage.color(tint, dark: false, highContrast: true), "\(tint) light, more contrast")
            assertClose(darkHigh, RoomStage.color(tint, dark: true, highContrast: true), "\(tint) dark, more contrast")
            XCTAssertGreaterThan(light.contrast(RoomStage.ink), 10, "\(tint)")
            XCTAssertGreaterThan(lightHigh.contrast(RoomStage.ink), 10, "\(tint)")
            XCTAssertGreaterThan(dark.contrast(RoomStage.ink), RoomStage.darkContrast - 0.1, "\(tint)")
            XCTAssertGreaterThan(darkHigh.contrast(RoomStage.ink), RoomStage.darkHighContrast - 0.1, "\(tint)")
            // More contrast is a real change of the dark stage.
            XCTAssertGreaterThan(darkHigh.contrast(RoomStage.ink), dark.contrast(RoomStage.ink) + 0.5, "\(tint)")
        }
    }

    // A SwiftUI view takes both facts from its environment: the same
    // colors, and the same bar in "dark, more contrast".
    func testStageFollowsTheEnvironment() throws {
        XCTAssertEqual(RoomStage.darkHighContrast - 0.1, 3.4, accuracy: 1e-9)
        for tint in RoomTint.allCases {
            let cases: [(ColorScheme, ColorSchemeContrast, Bool, Bool)] = [
                (.light, .standard, false, false), (.dark, .standard, true, false),
                (.light, .increased, false, true), (.dark, .increased, true, true),
            ]
            for (scheme, contrast, dark, high) in cases {
                assertClose(try fill(tint, scheme, contrast), RoomStage.color(tint, dark: dark, highContrast: high),
                            "\(tint) dark \(dark), more contrast \(high)")
            }
            let darkHigh = try fill(tint, .dark, .increased)
            XCTAssertGreaterThan(darkHigh.contrast(RoomStage.ink), RoomStage.darkHighContrast - 0.1, "\(tint)")
        }
    }

    // Dark Mode is read from an appearance. Increase Contrast is not: an
    // appearance made from a high contrast name can have a plain name, so
    // the stage has the contrast that the caller passes, in each of the
    // four appearances.
    func testAppearanceTraits() throws {
        let cases: [(NSAppearance.Name, Bool)] = [(.aqua, false), (.darkAqua, true),
                                                  (.accessibilityHighContrastAqua, false),
                                                  (.accessibilityHighContrastDarkAqua, true)]
        for (name, dark) in cases {
            let appearance = try XCTUnwrap(NSAppearance(named: name), name.rawValue)
            XCTAssertEqual(RoomStage.isDark(appearance), dark, "\(name.rawValue) is named \(appearance.name.rawValue)")
            for tint in RoomTint.allCases {
                for high in [false, true] {
                    assertClose(try stage(tint, name, highContrast: high),
                                RoomStage.color(tint, dark: dark, highContrast: high),
                                "\(tint) in \(name.rawValue), more contrast \(high)")
                }
            }
        }
        // Without a contrast, AppKit code gets the setting of the system.
        let system = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let read = RoomStage.increasesContrast
        XCTAssertEqual(read, system)
        for tint in RoomTint.allCases {
            assertClose(try rgb(RoomStage.nsColor(tint), in: .darkAqua),
                        RoomStage.color(tint, dark: true, highContrast: system), "\(tint) dark, the system contrast")
        }
    }

    // The room and its top inset fill the stage; a staged room draws at
    // the stage size, at every size it is used.
    func testStagedRoomRenders() throws {
        XCTAssertEqual(RoomStage.roomScale + RoomStage.topInset, 1, accuracy: 1e-9)
        XCTAssertEqual(RoomStage.roomSide(stage: 160), 144, accuracy: 1e-9)
        for (scene, side) in [(RoomScene.empty, RoomSize.welcome), (RoomScene.welcome, RoomSize.welcome),
                              (RoomScene(tint: .blue, color: .orange, pose: .wait, badge: 3), RoomSize.card),
                              (RoomScene(tint: .mint, color: .pink, pose: .idle, showsProgress: true), RoomSize.header)] {
            let renderer = ImageRenderer(content: StagedRoom(scene: scene, icon: .app(path: "/nonexistent/Gone.app"), side: side))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(scene)")
            XCTAssertEqual(image.width, Int(side * 2))
            XCTAssertEqual(image.height, Int(side * 2))
        }
        // The largest card room and the header room stay inside the
        // pixels the loader keeps, and so does the character in them.
        let largest = RoomStage.roomSide(stage: RoomCardLook.stageSide(cardWidth: RoomSize.maxCardWidth))
        XCTAssertLessThanOrEqual(Int(largest * 2), RoomArtLoader.roomPixels)
        XCTAssertLessThanOrEqual(Int(RoomStage.roomSide(stage: RoomSize.header) * 2), RoomArtLoader.roomPixels)
        let character = IconPlacement.characterBox(RoomArtLoader.shared.manifest, tint: .cream, side: Double(largest))
        XCTAssertLessThanOrEqual(Int(character.size * 2), RoomArtLoader.characterPixels)
    }

    // The work loop ends at the underside of the desk; the other loops
    // and the placeholder show in full.
    func testWorkLoopIsCutAtTheDesk() {
        let side: CGFloat = 256
        let box = CharacterBox(x: 30, y: 38, size: 131)
        XCTAssertEqual(RoomView.characterHeight(.work, box: box, side: side, placeholder: false), 163 - 38, accuracy: 1e-6)
        XCTAssertEqual(RoomView.characterHeight(.idle, box: box, side: side, placeholder: false), 131)
        XCTAssertEqual(RoomView.characterHeight(.work, box: box, side: side, placeholder: true), 131)
        let high = CharacterBox(x: 0, y: 0, size: 100)
        XCTAssertEqual(RoomView.characterHeight(.work, box: high, side: side, placeholder: false), 100, "never more than the sprite")
    }

    // The add-app room: the next tint of the rotation, the gray character awake.
    func testAddRoomScene() {
        XCTAssertEqual(AddRoomCard.scene(after: 0), RoomScene(tint: .cream, color: .gray, pose: .idle))
        XCTAssertEqual(AddRoomCard.scene(after: 2).tint, .lilac)
        XCTAssertNil(AddRoomCard.scene(after: 2).badge)
    }

    // The stage is not a flat gray: its corners are clear (rounded) and
    // its middle top edge has the stage color.
    func testStageIsDrawnBehindTheRoom() throws {
        let side = RoomSize.card
        let renderer = ImageRenderer(content: StagedRoom(scene: RoomScene(tint: .lilac, color: .teal, pose: .sleep),
                                                         icon: .app(path: nil), side: side))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
        XCTAssertLessThan(corner.alphaComponent, 0.1, "the stage has round corners")
        let edge = try XCTUnwrap(bitmap.colorAt(x: Int(side / 2), y: 2))
        XCTAssertGreaterThan(edge.alphaComponent, 0.9, "the stage fills its square")
    }

    // MARK: Art of the grid

    // The grid holds each loop, room and the front layer once, in room order.
    func testGridArtKeys() {
        let scenes = [RoomScene(tint: .cream, color: .orange, pose: .idle),
                      RoomScene(tint: .blue, color: .orange, pose: .idle),
                      RoomScene(tint: .cream, color: .teal, pose: .sleep),
                      RoomScene(tint: .blue, color: .orange, pose: .work)]
        XCTAssertEqual(RoomArtLoader.keys(scenes),
                       [.room(.cream), .character(.orange, .idle), .front, .room(.blue), .character(.teal, .sleep),
                        .character(.orange, .work)])
        XCTAssertEqual(RoomArtLoader.keys([RoomScene]()), [])
    }

    // While the grid holds the art, a card that scrolls off and on again
    // does not load a PNG a second time. When the grid goes, the art goes.
    func testScrollDoesNotLoadArtAgain() {
        var asked: [String] = []
        let image = NSImage(size: NSSize(width: 4, height: 4))
        let loader = RoomArtLoader(lookup: { name in
            asked.append(name)
            return name.hasSuffix("-3") ? nil : image
        }, manifestData: { nil })
        let scene = RoomScene(tint: .mint, color: .pink, pose: .sleep)
        let grid = RoomArtLoader.keys([scene, RoomScene(tint: .lilac, color: .green, pose: .blocked)])
        loader.hold(grid)

        // The card comes on screen, draws, and scrolls off.
        let card = RoomArtLoader.keys(scene)
        loader.hold(card)
        _ = loader.room(scene.tint)
        _ = loader.front()
        XCTAssertEqual(loader.character(scene.color, .sleep).count, 2)
        let first = asked.count
        loader.release(card)
        XCTAssertTrue(card.allSatisfy { loader.isLoaded($0) }, "the grid still holds the art")

        // It scrolls on again: nothing is asked of the catalog.
        loader.hold(card)
        _ = loader.room(scene.tint)
        _ = loader.front()
        _ = loader.character(scene.color, .sleep)
        XCTAssertEqual(asked.count, first, "\(asked)")

        // The art of a room below the window edge loads before it shows.
        let below = RoomArtKey.character(.green, .blocked)
        XCTAssertFalse(loader.isLoaded(below))
        loader.load(below)
        loader.load(.room(.lilac))
        XCTAssertTrue(loader.isLoaded(below))
        XCTAssertTrue(loader.isLoaded(.room(.lilac)))
        let warmed = asked.count
        loader.load(below)
        XCTAssertEqual(asked.count, warmed, "a loaded loop is not read again")

        // The grid goes: all of it is released.
        loader.release(card)
        loader.release(grid)
        XCTAssertFalse(grid.contains { loader.isLoaded($0) })
    }
}
