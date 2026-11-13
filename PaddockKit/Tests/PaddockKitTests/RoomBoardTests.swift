import Foundation
import XCTest
@testable import PaddockKit

/// The rules that keep the Rooms view smooth: the scenes of all rooms in
/// one pass, the shared tick of the sprite loops, the frame work of 30
/// rooms on a fake display clock, and the stage colors.
final class RoomBoardTests: XCTestCase {
    // MARK: The board

    // The board is the sidebar order, and each entry is the scene the
    // single-app rule gives.
    func testBoardMatchesTheSingleAppRule() throws {
        let apps = [
            app("sample-notes", state: "running"),
            app("sample-mail", state: "stopped"),
            app("sample-notes", state: "stopped", home: "instance-2"),
            app("sample-draw", state: "error"),
        ]
        let questions = [
            QuestionJSON(id: "1", app: "sample-notes", host: "example.com", port: 443),
            QuestionJSON(id: "2", app: "sample-notes", host: "example.org", port: 443),
            QuestionJSON(id: "3", app: "sample-draw", host: "example.net", port: 443),
        ]
        let board = RoomBoard.of(apps, questions: questions)
        XCTAssertEqual(board.keys, ["sample-notes", "sample-notes--2", "sample-mail", "sample-draw"])
        XCTAssertEqual(board.entries.map(\.questions), [2, 2, 0, 1], "instances share the questions of their app")
        let colors = CharacterColor.spread(["sample-notes", "sample-mail", "sample-draw"])
        for (index, entry) in board.entries.enumerated() {
            // The single-app rule, with the color of the spread.
            var scene = RoomScene.of(entry.app, index: index, questions: entry.questions)
            scene.color = try XCTUnwrap(colors[entry.app.name])
            XCTAssertEqual(entry.scene, scene, entry.id)
            XCTAssertEqual(entry.scene.tint, RoomTint.at(index))
        }
        XCTAssertEqual(board.entries[0].scene.color, board.entries[1].scene.color, "instances share a character")
        XCTAssertEqual(Set(board.entries.map(\.scene.color)).count, 3, "three apps, three characters")
        XCTAssertEqual(board.entries[0].scene.pose, .wait)
        XCTAssertEqual(board.entries[0].scene.badge, 2)
        XCTAssertEqual(board.entries[2].scene.pose, .sleep)
        XCTAssertEqual(board.entries[3].scene.pose, .blocked, "a failure wins over a question")
        XCTAssertNil(board.entries[3].scene.badge)
    }

    func testEmptyBoard() {
        XCTAssertEqual(RoomBoard.of([], questions: []).entries, [])
        XCTAssertEqual(RoomBoard.questionCounts([]), [:])
        XCTAssertEqual(RoomScene.empty, RoomScene(tint: .cream, color: .gray, pose: .sleep))
    }

    // 30 rooms: one entry each, every key once.
    func testThirtyRooms() {
        let apps = (0..<30).map { app("app-\($0)", state: $0 % 2 == 0 ? "running" : "stopped") }
        let board = RoomBoard.of(apps, questions: [])
        XCTAssertEqual(board.entries.count, 30)
        XCTAssertEqual(Set(board.keys).count, 30)
        XCTAssertEqual(board.keys, apps.map(\.key))
    }

    // MARK: Character colors

    // Up to six apps all differ, whatever their names; an app whose name
    // color is free keeps it.
    func testSixAppsGetSixCharacters() {
        for names in [["a", "b", "c", "d", "e", "f"], ["sample-notes", "sample-mail"],
                      (0..<6).map { "app-\($0)" }, ["x", "x", "x", "y"]] {
            let colors = CharacterColor.spread(names)
            XCTAssertEqual(colors.count, Set(names).count)
            XCTAssertEqual(Set(colors.values).count, Set(names).count, "\(names): \(colors)")
            XCTAssertFalse(colors.values.contains(.gray), "gray is the launcher's own character")
            XCTAssertEqual(colors[names[0]], CharacterColor.of(app: names[0]), "the first app keeps the color of its name")
        }
        XCTAssertEqual(CharacterColor.spread([]), [:])
    }

    // With more apps than colors, no app has the color of one of the
    // five apps before it: the nearest same character is six rooms away.
    func testNeighborsNeverShareACharacter() {
        let names = (0..<30).map { "app-\($0)" }
        let colors = CharacterColor.spread(names)
        let row = names.compactMap { colors[$0] }
        XCTAssertEqual(row.count, 30)
        for index in row.indices {
            for back in 1...5 where index - back >= 0 {
                XCTAssertNotEqual(row[index], row[index - back], "rooms \(index - back) and \(index)")
            }
        }
        XCTAssertEqual(Set(row).count, CharacterColor.appColors.count, "every color is used")
        XCTAssertEqual(CharacterColor.spread(names), colors, "the same list gives the same characters")
    }

    // MARK: Grid fit

    // Cards of 200 to 280 pt, 16 pt apart.
    func fit(_ width: Double, _ cells: Int) -> RoomGridFit {
        RoomGridNavigation.fit(width: width, cells: cells, minCard: 200, maxCard: 280, spacing: 16)
    }

    // Two apps and the add card in a wide window: three large cards, not
    // three small ones in a corner.
    func testFewCardsGrow() {
        XCTAssertEqual(fit(900, 3), RoomGridFit(columns: 3, cardWidth: 280))
        XCTAssertEqual(fit(700, 3), RoomGridFit(columns: 3, cardWidth: 222))
        XCTAssertEqual(fit(900, 1), RoomGridFit(columns: 1, cardWidth: 280))
        XCTAssertEqual(fit(900, 0), RoomGridFit(columns: 1, cardWidth: 280))
    }

    // A full grid: as many columns as fit, and the cards fill the row.
    func testManyCardsFillTheRow() {
        XCTAssertEqual(fit(900, 31), RoomGridFit(columns: 4, cardWidth: 213))
        XCTAssertEqual(fit(848, 31), RoomGridFit(columns: 4, cardWidth: 200))
        XCTAssertEqual(fit(847, 31), RoomGridFit(columns: 3, cardWidth: 271))
        for width in stride(from: 200.0, through: 2000.0, by: 37) {
            let result = fit(width, 31)
            XCTAssertGreaterThanOrEqual(result.cardWidth, 200)
            XCTAssertLessThanOrEqual(result.cardWidth, 280)
            let used = Double(result.columns) * result.cardWidth + Double(result.columns - 1) * 16
            XCTAssertLessThanOrEqual(used, width, "\(width)")
            XCTAssertEqual(result.columns, RoomGridNavigation.columns(width: width, cardWidth: 200, spacing: 16))
        }
    }

    // A window narrower than a card: one column of the least width.
    func testNarrowWindow() {
        XCTAssertEqual(fit(120, 5), RoomGridFit(columns: 1, cardWidth: 200))
        XCTAssertEqual(fit(0, 5), RoomGridFit(columns: 1, cardWidth: 200))
    }

    // MARK: The shared tick

    func testAlignedStartIsOnTheGrid() {
        let tick = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(SpritePlayer.aligned(tick), tick, "a date on a tick stays")
        XCTAssertEqual(SpritePlayer.aligned(tick.addingTimeInterval(0.001)), tick.addingTimeInterval(0.125))
        XCTAssertEqual(SpritePlayer.aligned(tick.addingTimeInterval(0.124)), tick.addingTimeInterval(0.125))
        XCTAssertEqual(SpritePlayer.aligned(tick.addingTimeInterval(0.126)), tick.addingTimeInterval(0.25))
        for offset in stride(from: 0.0, to: 2.0, by: 0.0137) {
            let date = tick.addingTimeInterval(offset)
            let aligned = SpritePlayer.aligned(date)
            XCTAssertGreaterThanOrEqual(aligned, date)
            XCTAssertLessThan(aligned.timeIntervalSince(date), SpritePlayer.frameInterval)
            let ticks = aligned.timeIntervalSince(SpritePlayer.epoch) * SpritePlayer.fps
            XCTAssertEqual(ticks, ticks.rounded(), "\(offset)")
        }
    }

    // A loop that starts on a tick shows frame 0 until the next tick.
    func testAlignedLoopStartsAtFrameZero() {
        let start = SpritePlayer.aligned(Date(timeIntervalSinceReferenceDate: 800_000_000.03))
        let player = SpritePlayer(frameCount: 8, start: start)
        XCTAssertEqual(player.frame(at: start.addingTimeInterval(-0.05), playing: true), 0, "before the start")
        XCTAssertEqual(player.frame(at: start, playing: true), 0)
        XCTAssertEqual(player.frame(at: start.addingTimeInterval(0.124), playing: true), 0)
        XCTAssertEqual(player.frame(at: start.addingTimeInterval(0.125), playing: true), 1)
    }

    // MARK: Frame work with a fake clock

    /// 30 rooms that became visible at different moments, 11 ms apart.
    func starts(from: Date, aligned: Bool) -> [Date] {
        (0..<30).map { index in
            let start = from.addingTimeInterval(-Double(index) * 0.011)
            return aligned ? SpritePlayer.aligned(start) : start
        }
    }

    func players(_ starts: [Date]) -> [SpritePlayer] {
        starts.enumerated().map { index, start in SpritePlayer(frameCount: index % 3 == 0 ? 4 : 8, start: start) }
    }

    // One second of a 60 Hz display with 30 rooms. On the shared tick the
    // 240 sprite changes land in 8 display frames; 52 frames have no
    // work. Without it, almost every display frame has a change.
    func testThirtyRoomsShareEightBusyFrames() {
        let from = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let shared = SpriteFrameWork.measure(players(starts(from: from, aligned: true)), playing: true, from: from, frames: 60)
        XCTAssertEqual(shared.frames, 60)
        XCTAssertEqual(shared.updates, 30 * 8, "each room shows 8 frames a second")
        XCTAssertEqual(shared.busyFrames, 8, "all rooms change in the same display frames")

        let loose = SpriteFrameWork.measure(players(starts(from: from, aligned: false)), playing: true, from: from, frames: 60)
        XCTAssertEqual(loose.updates, 30 * 8)
        XCTAssertGreaterThan(loose.busyFrames, 40, "each room on its own clock keeps the display busy")
    }

    // Ten seconds stay at 8 busy frames a second: the ticks do not drift.
    func testSharedTickDoesNotDrift() {
        let from = Date(timeIntervalSinceReferenceDate: 800_000_000.5)
        let work = SpriteFrameWork.measure(players(starts(from: from, aligned: true)), playing: true, from: from, frames: 600)
        XCTAssertEqual(work.busyFrames, 80)
        XCTAssertEqual(work.updates, 30 * 80)
        // A 120 Hz display has the same 8 busy frames a second.
        let fast = SpriteFrameWork.measure(players(starts(from: from, aligned: true)), playing: true, from: from,
                                           frames: 120, refreshRate: 120)
        XCTAssertEqual(fast.busyFrames, 8)
    }

    // A hidden window, a room off screen or Reduce Motion: no frame work.
    func testNoFrameWorkWhileNotPlaying() {
        let from = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let all = players(starts(from: from, aligned: true))
        for (visible, onScreen, reduce) in [(false, true, false), (true, false, false), (true, true, true)] {
            let playing = SpritePlayer.isPlaying(windowVisible: visible, onScreen: onScreen, reduceMotion: reduce, frameCount: 8)
            XCTAssertFalse(playing)
            let work = SpriteFrameWork.measure(all, playing: playing, from: from, frames: 600)
            XCTAssertEqual(work, SpriteFrameWork(updates: 0, busyFrames: 0, frames: 600))
        }
        XCTAssertEqual(SpriteFrameWork.measure([], playing: true, from: from, frames: 60).busyFrames, 0)
        XCTAssertEqual(SpriteFrameWork.measure(all, playing: true, from: from, frames: 0),
                       SpriteFrameWork(updates: 0, busyFrames: 0, frames: 0))
    }

    // MARK: Stage colors

    func testContrastRule() {
        XCTAssertEqual(RGB(1, 1, 1).contrast(RGB(0, 0, 0)), 21, accuracy: 1e-9)
        XCTAssertEqual(RGB(0.5, 0.5, 0.5).contrast(RGB(0.5, 0.5, 0.5)), 1, accuracy: 1e-9)
        XCTAssertEqual(RGB(0, 0, 0).contrast(RGB(1, 1, 1)), RGB(1, 1, 1).contrast(RGB(0, 0, 0)), accuracy: 1e-9)
    }

    // The dark outline of the art reads on the stage in every appearance,
    // and each tint keeps its own stage color.
    func testOutlineReadsOnEveryStage() {
        for tint in RoomTint.allCases {
            let light = RoomStage.color(tint, dark: false, highContrast: false)
            XCTAssertGreaterThan(light.contrast(RoomStage.ink), 10, "\(tint) light")
            XCTAssertGreaterThan(RoomStage.color(tint, dark: false, highContrast: true).contrast(RoomStage.ink), 10)
            let dark = RoomStage.color(tint, dark: true, highContrast: false)
            XCTAssertGreaterThan(dark.contrast(RoomStage.ink), RoomStage.darkContrast, "\(tint) dark")
            XCTAssertLessThan(dark.luminance, 0.2, "\(tint): a dark stage stays quiet in a dark window")
            let high = RoomStage.color(tint, dark: true, highContrast: true)
            XCTAssertGreaterThan(high.contrast(RoomStage.ink), RoomStage.darkHighContrast, "\(tint) dark, more contrast")
            XCTAssertGreaterThan(high.luminance, dark.luminance)
        }
        for dark in [false, true] {
            let colors = RoomTint.allCases.map { RoomStage.color($0, dark: dark, highContrast: false) }
            for (index, color) in colors.enumerated() {
                XCTAssertFalse(colors[(index + 1)...].contains(color), "two tints share a stage")
            }
        }
    }

    // MARK: Helpers

    func app(_ name: String, state: String, home: String? = nil) -> AppItem {
        var fields: [String: Any] = ["name": name, "state": state]
        if state == "error" { fields["reason"] = "The VM stopped" }
        if let home { fields["home"] = home }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return AppItem(json: try! PaddockJSON.decoder.decode(AppJSON.self, from: data))
    }
}
