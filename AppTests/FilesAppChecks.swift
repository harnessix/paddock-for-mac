import AppKit
import PaddockKit
import SwiftUI
import XCTest
@testable import PaddockLauncher

/// The Files screens in the app target: the symbols exist, the spoken
/// lines, the paths of the two sides, and the preview of the fixture tree
/// (Fixtures/files-tree) read from the disk.
@MainActor
final class FilesAppChecks: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // AppTests
        .deletingLastPathComponent() // launcher

    static var tree: URL { root.appendingPathComponent("Fixtures/files-tree") }

    /// The changes fixture, with the copy and the project in the fixture tree.
    func doc() throws -> ChangesDoc {
        let url = FilesAppChecks.root.appendingPathComponent("Fixtures/copy-v1/changes.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "/Users/demo/.local/share/paddock/copies/7c1d9e42/runs/claude-1a2b3c/tree",
            with: FilesAppChecks.tree.appendingPathComponent("copy").path)
        text = text.replacingOccurrences(of: "/Users/demo/src/shop", with: FilesAppChecks.tree.appendingPathComponent("original").path)
        return try ChangesDoc.decode(Data(text.utf8))
    }

    func row(_ path: String, in doc: ChangesDoc) throws -> FileRow {
        try XCTUnwrap(FileRows.rows(doc, filter: .changes).first { $0.path == path })
    }

    // MARK: Symbols

    /// Every SF Symbol of the Files screens exists on this macOS: a
    /// symbol that does not exist draws nothing.
    func testEverySymbolExists() throws {
        var names = FileMark.allCases.map(\.symbol)
        names += ["folder", "arrow.down.doc", "arrow.down.doc.fill", "pause.circle", "trash", "pencil.line",
                  "clock.arrow.circlepath", "shippingbox", "questionmark.folder", "doc.on.doc", "magnifyingglass",
                  "xmark.circle.fill", "chevron.left", "chevron.right", "chevron.down", "link", "ellipsis",
                  "checkmark.circle.fill", "checkmark.circle", "checkmark", "circle.fill", "exclamationmark.triangle",
                  "arrow.left.and.right.circle.fill", "lock.fill", "lock.open", "questionmark.circle",
                  "externaldrive.fill.badge.checkmark", "externaldrive.badge.exclamationmark", "camera.circle",
                  "arrow.uturn.backward.circle", "arrow.uturn.backward.circle.fill",
                  "externaldrive.fill.badge.timemachine"]
        for name in names {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "no SF Symbol \(name)")
        }
        // The symbols that the Kit chooses.
        let backups = try BackupsDoc.decode(try Data(contentsOf: FilesAppChecks.root.appendingPathComponent("Fixtures/copy-v1/backups.json")))
        for day in BackupTimeline.days(backups, now: Date()) {
            for point in day.points {
                XCTAssertNotNil(NSImage(systemSymbolName: point.symbol, accessibilityDescription: nil), point.symbol)
            }
        }
        for name in ["pointer.json", "pointer-moved.json", "pointer-none.json"] {
            let pointer = try PointerDoc.decode(try Data(contentsOf: FilesAppChecks.root.appendingPathComponent("Fixtures/copy-v1/" + name)))
            let summary = PointerSummary(pointer.part, doc: pointer)
            XCTAssertNotNil(NSImage(systemSymbolName: summary.symbol, accessibilityDescription: nil), summary.symbol)
            XCTAssertNotNil(NSImage(systemSymbolName: summary.encryptionSymbol, accessibilityDescription: nil),
                            summary.encryptionSymbol)
        }
    }

    // MARK: Texts

    /// VoiceOver reads a row as "main.rs, changed, 12 lines added, 3 removed".
    func testSpokenRow() throws {
        let main = FileRow(FileChange(path: "src/main.rs", kind: .changed, added: 12, removed: 3))
        XCTAssertEqual(FilesText.spoken(main), "main.rs, changed, 12 lines added, 3 removed")
        let doc = try doc()
        XCTAssertEqual(FilesText.spoken(try row("docs/notes.md", in: doc)), "notes.md, new, 4 lines added")
        XCTAssertEqual(FilesText.spoken(try row("src/legacy/old-cart.ts", in: doc)), "old-cart.ts, deleted, 61 lines removed")
    }

    /// The texts of the Files screens resolve through the catalog.
    func testCatalogHasTheFilesTexts() {
        for key in ["No changes yet", "Your folder stays as it is.", "Apply to Original…", "Keep in the Copy", "Discard…",
                    "Apply All…", "Discard All…", "Changes", "All files", "Conflicts", "Name", "Change", "Size", "Time",
                    FilesCopy.emptyLine.key] {
            XCTAssertEqual(Bundle.main.localizedString(forKey: key, value: "MISSING", table: nil), key)
        }
        XCTAssertEqual(FilesCopy.emptyLine.localized, "No changes yet. Your folder stays as it is.")
    }

    func testTimeColumn() {
        let now = Date(timeIntervalSince1970: 1_793_959_200)
        XCTAssertEqual(FilesText.time(now.addingTimeInterval(-600), now: now)?.localized, "10 min ago")
        XCTAssertNil(FilesText.time(nil, now: now))
    }

    // MARK: Paths

    func testPathsOfTheTwoSides() throws {
        let doc = try doc()
        try XCTSkipIf(FilesPaths.debugRoot != nil, "the test host has PADDOCK_LAUNCHER_FILES_ROOT")
        XCTAssertEqual(FilesPaths.copyRoot(doc.run), FilesAppChecks.tree.appendingPathComponent("copy").path)
        XCTAssertEqual(FilesPaths.originalRoot(doc.run), FilesAppChecks.tree.appendingPathComponent("original").path)
        XCTAssertEqual(FilesPaths.url("/p", "src/cart.ts").path, "/p/src/cart.ts")
        // Quick Look opens the copy's file, or yours for a deleted file.
        XCTAssertEqual(FilesPaths.best(try row("src/cart.ts", in: doc), run: doc.run)?.path,
                       FilesAppChecks.tree.appendingPathComponent("copy/src/cart.ts").path)
        XCTAssertNil(FilesPaths.best(try row("src/legacy/old-cart.ts", in: doc), run: doc.run), "on neither side")
    }

    func testRelativePathOfAChosenFile() {
        XCTAssertEqual(FilePicker.relative("/Users/demo/src/shop/src/cart.ts", to: "/Users/demo/src/shop"), "src/cart.ts")
        XCTAssertEqual(FilePicker.relative("/Users/demo/src/shop/a.txt", to: "/Users/demo/src/shop/"), "a.txt")
        XCTAssertNil(FilePicker.relative("/Users/demo/src/shop", to: "/Users/demo/src/shop"))
        XCTAssertNil(FilePicker.relative("/Users/demo/src/shopping/a.txt", to: "/Users/demo/src/shop"))
        XCTAssertNil(FilePicker.relative("/Users/demo/src/shop/../other/a.txt", to: "/Users/demo/src/shop"))
    }

    func testWhatCountsAsAPicture() {
        XCTAssertTrue(FileIcons.isImage("assets/logo.png"))
        XCTAssertTrue(FileIcons.isImage("a/b/Photo.JPG"))
        XCTAssertFalse(FileIcons.isImage("src/cart.ts"))
        XCTAssertFalse(FileIcons.isImage("Makefile"))
        XCTAssertFalse(FileIcons.isImage("icon.svg"), "an SVG is text: it shows as a diff")
        XCTAssertGreaterThan(FileIcons.icon("src/cart.ts").size.width, 0)
        XCTAssertGreaterThan(FileIcons.folder.size.width, 0)
    }

    // MARK: Preview

    func testPreviewOfAChangedTextFile() async throws {
        try XCTSkipIf(FilesPaths.debugRoot != nil, "the test host has PADDOCK_LAUNCHER_FILES_ROOT")
        let doc = try doc()
        guard case .text(let diff) = await PreviewLoader.load(try row("src/cart.ts", in: doc), run: doc.run) else {
            return XCTFail("no text diff")
        }
        XCTAssertEqual(diff.added, 12)
        XCTAssertEqual(diff.removed, 3)
        // Your file is the left side, the copy's the right.
        let rows = diff.rows()
        XCTAssertEqual(rows.first?.left?.text, #"import { Item } from "./item";"#)
        XCTAssertTrue(rows.contains { $0.right?.text == #"import { round } from "./money";"# && $0.left == nil })
        XCTAssertTrue(rows.contains { $0.kind == .changed && $0.left?.text == "    sum += item.price;" })
    }

    func testPreviewOfANewFileAndAPicture() async throws {
        try XCTSkipIf(FilesPaths.debugRoot != nil, "the test host has PADDOCK_LAUNCHER_FILES_ROOT")
        let doc = try doc()
        // A new file: every line is added.
        guard case .text(let diff) = await PreviewLoader.load(try row("docs/notes.md", in: doc), run: doc.run) else {
            return XCTFail("no text diff")
        }
        XCTAssertEqual([diff.added, diff.removed], [4, 0])
        guard case .image(let original, let copy) = await PreviewLoader.load(try row("assets/logo.png", in: doc), run: doc.run) else {
            return XCTFail("no picture")
        }
        XCTAssertNotNil(original)
        XCTAssertNotNil(copy)
        // A symlink shows its targets and reads no file.
        guard case .link(let from, let to) = await PreviewLoader.load(try row("src/vendor/current", in: doc), run: doc.run) else {
            return XCTFail("no link")
        }
        XCTAssertEqual(from, "v2.0.4")
        XCTAssertEqual(to, "v2.1.0")
        // A file that is on neither side.
        guard case .missing = await PreviewLoader.load(try row("src/checkout.ts", in: doc), run: doc.run) else {
            return XCTFail("the file is not in the fixture tree")
        }
    }

    // MARK: The diff and the stage

    func testDiffStyle() {
        XCTAssertEqual(DiffStyle.shown(""), " ", "an empty line keeps its height")
        XCTAssertEqual(DiffStyle.shown("\tx"), "    x")
        XCTAssertEqual(DiffStyle.shown("plain"), "plain")
        XCTAssertGreaterThan(DiffStyle.gutter(12_000), DiffStyle.gutter(99))
        XCTAssertEqual(DiffStyle.gutter(3), DiffStyle.gutter(99), "at least two digits wide")
    }

    func testStageGeometryAndMotion() {
        XCTAssertEqual(ApplyStage.width, ApplyStage.tile * 2 + ApplyStage.gap)
        XCTAssertEqual(ApplyMotion.seconds, 0.7, "the move from the desk to the house takes 700 ms")
        // A UI test run is still: the check mark shows in place of the move.
        XCTAssertEqual(ApplyMotion.style(changes: 3, reduceMotion: false, still: true), .check)
        XCTAssertEqual(StagePalette.parts.count, ApplyMotion.maxParts)
    }

    /// The folder tree is a flat list: each folder, then its folders, one step in.
    func testFolderTreeOrder() throws {
        let doc = try doc()
        let items = FolderTree.items(FileRows.tree(FileRows.rows(doc, filter: .changes), root: "shop"))
        XCTAssertEqual(items.map(\.node.path), ["", "assets", "docs", "scripts", "src", "src/legacy", "src/vendor"])
        XCTAssertEqual(items.map(\.depth), [0, 1, 1, 1, 1, 2, 2])
        XCTAssertEqual(items.first?.node.name, "shop")
    }

    func testSheetsHaveStableIds() throws {
        let doc = try doc()
        XCTAssertEqual(FilesSheet.backups.id, "backups")
        XCTAssertEqual(FilesSheet.apply(ApplyPlan(doc, paths: ["src/cart.ts"])).id, "apply:src/cart.ts")
        XCTAssertNotEqual(FilesSheet.apply(ApplyPlan(doc)).id, FilesSheet.apply(ApplyPlan(doc, paths: ["src/cart.ts"])).id)
    }
}
