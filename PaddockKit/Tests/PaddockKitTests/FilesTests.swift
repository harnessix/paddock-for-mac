import XCTest
@testable import PaddockKit

/// The rules of the Files screens: the marks, the rows, the folder tree,
/// the text diff, the Apply sheet, the backup timeline, the pointer and
/// the command lines.
final class FilesRuleTests: XCTestCase {
    func doc(_ name: String = "changes.json") throws -> ChangesDoc {
        try ChangesDoc.decode(try Data(contentsOf: FilesContractTests.folder.appendingPathComponent(name)))
    }

    let now = Date(timeIntervalSince1970: 1_793_959_200)
    let utc = TimeZone(identifier: "UTC")!

    // MARK: Marks

    /// A symbol and a word for each mark, as the design names them.
    func testMarksAreASymbolAndAWord() {
        XCTAssertEqual(FileMark.new.symbol, "plus.circle.fill")
        XCTAssertEqual(FileMark.new.word.english, "New")
        XCTAssertEqual(FileMark.changed.symbol, "pencil.circle.fill")
        XCTAssertEqual(FileMark.changed.word.english, "Changed")
        XCTAssertEqual(FileMark.deleted.symbol, "minus.circle.fill")
        XCTAssertEqual(FileMark.deleted.word.english, "Deleted")
        XCTAssertEqual(FileMark.conflict.symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(FileMark.conflict.word.english, "Conflict")
        XCTAssertEqual(FileMark.kept.symbol, "pause.circle")
        XCTAssertEqual(FileMark.kept.word.english, "Kept")
        // No two marks share a symbol or a word.
        XCTAssertEqual(Set(FileMark.allCases.map(\.symbol)).count, FileMark.allCases.count)
        XCTAssertEqual(Set(FileMark.allCases.map(\.word.english)).count, FileMark.allCases.count)
    }

    func testMarkOfAChange() throws {
        let marks = try doc().changes.map { FileMark.of($0) }
        XCTAssertEqual(marks, [.conflict, .changed, .new, .kept, .changed, .conflict, .deleted, .changed])
    }

    // MARK: Rows

    func testRowsOfEachFilter() throws {
        let doc = try doc()
        let changes = FileRows.rows(doc, filter: .changes)
        XCTAssertEqual(changes.map(\.path), [
            "assets/logo.png", "docs/notes.md", "README.md", "scripts/deploy.sh", "src/cart.ts", "src/checkout.ts",
            "src/legacy/old-cart.ts", "src/vendor/current",
        ])
        XCTAssertEqual(FileRows.rows(doc, filter: .conflicts).map(\.path), ["README.md", "src/checkout.ts"])
        // All files: the files of the copy, and the deleted one that the copy no longer has.
        let listed = [ListedFile(path: "package.json", size: 512, modified: now), ListedFile(path: "src/cart.ts", size: 402),
                      ListedFile(path: "src/item.ts", size: 90)]
        let all = FileRows.rows(doc, filter: .all, listed: listed)
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(all.first { $0.path == "package.json" }?.mark, .same)
        XCTAssertEqual(all.first { $0.path == "package.json" }?.size, 512)
        XCTAssertEqual(all.first { $0.path == "src/cart.ts" }?.mark, .changed, "the change wins over the listing")
        XCTAssertEqual(all.first { $0.path == "src/legacy/old-cart.ts" }?.mark, .deleted)
        XCTAssertFalse(all.first { $0.path == "src/item.ts" }!.isChange)
    }

    /// The size and the time of a row: the copy's file, or yours for a
    /// deleted file.
    func testRowSizeAndTime() throws {
        let rows = FileRows.rows(try doc(), filter: .changes)
        let cart = try XCTUnwrap(rows.first { $0.path == "src/cart.ts" })
        XCTAssertEqual(cart.size, 402)
        XCTAssertEqual(cart.time, now.addingTimeInterval(-60))
        XCTAssertEqual(cart.name, "cart.ts")
        XCTAssertEqual(cart.folder, "src")
        let old = try XCTUnwrap(rows.first { $0.path == "src/legacy/old-cart.ts" })
        XCTAssertEqual(old.size, 1840)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.path == "README.md" }).folder, "")
    }

    func testFolderTreeCountsTheChangesBelow() throws {
        let doc = try doc()
        let tree = FileRows.tree(FileRows.rows(doc, filter: .changes), root: "shop")
        XCTAssertEqual(tree.name, "shop")
        XCTAssertEqual(tree.path, "")
        XCTAssertEqual(tree.changes, 8)
        XCTAssertEqual(tree.conflicts, 2)
        XCTAssertEqual(tree.children.map(\.name), ["assets", "docs", "scripts", "src"])
        XCTAssertEqual(tree.children.map(\.changes), [1, 1, 1, 4])
        let src = tree.children[3]
        XCTAssertEqual(src.path, "src")
        XCTAssertEqual(src.conflicts, 1)
        XCTAssertEqual(src.children.map(\.path), ["src/legacy", "src/vendor"])
        XCTAssertEqual(src.children.map(\.changes), [1, 1])
        XCTAssertNil(src.children[0].folders, "a folder with no folders has no arrow")
        XCTAssertNotNil(src.folders)

        // All files: a folder with no change has the count 0.
        let all = FileRows.rows(doc, filter: .all, listed: [ListedFile(path: "test/cart.test.ts", size: 10)])
        let wide = FileRows.tree(all, root: "shop")
        XCTAssertEqual(wide.children.map(\.name), ["assets", "docs", "scripts", "src", "test"])
        XCTAssertEqual(wide.children.last?.changes, 0)
        XCTAssertEqual(wide.changes, 8)
    }

    func testRowsInAFolderAndTheSearch() throws {
        let doc = try doc()
        let rows = FileRows.rows(doc, filter: .changes)
        XCTAssertEqual(FileRows.inFolder(rows, "src").map(\.path),
                       ["src/cart.ts", "src/checkout.ts", "src/legacy/old-cart.ts", "src/vendor/current"])
        XCTAssertEqual(FileRows.inFolder(rows, "src/legacy").map(\.path), ["src/legacy/old-cart.ts"])
        XCTAssertEqual(FileRows.inFolder(rows, "").count, 8)
        // `sr` is no folder: a prefix of a name does not count.
        XCTAssertEqual(FileRows.inFolder(rows, "sr"), [])
        XCTAssertEqual(FileRows.search(rows, "CART").map(\.path), ["src/cart.ts", "src/legacy/old-cart.ts"])
        XCTAssertEqual(FileRows.search(rows, "src .ts cart").map(\.path), ["src/cart.ts", "src/legacy/old-cart.ts"])
        XCTAssertEqual(FileRows.search(rows, "  ").count, 8)
        XCTAssertEqual(FileRows.search(rows, "nothing"), [])
        XCTAssertEqual(FileRows.changePaths(doc, in: "src/vendor"), ["src/vendor/current"])
        XCTAssertEqual(FileRows.changePaths(doc, in: "").count, 8)
    }

    func testListingOfACopyFolder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paddock-copy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["src/deep", ".git/objects", "node_modules/x"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (path, text) in [("a.txt", "12345"), ("src/b.ts", "1"), ("src/deep/c.ts", ""), (".git/HEAD", "ref"),
                             ("node_modules/x/index.js", "x"), (".env", "A=1")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        let all = CopyDisk.list(root: root.path)
        XCTAssertEqual(all.files.map(\.path).sorted(), [".env", "a.txt", "src/b.ts", "src/deep/c.ts"])
        XCTAssertEqual(all.files.first { $0.path == "a.txt" }?.size, 5)
        XCTAssertNotNil(all.files.first { $0.path == "a.txt" }?.modified)
        XCTAssertFalse(all.more)
        let few = CopyDisk.list(root: root.path, limit: 2)
        XCTAssertEqual(few.files.count, 2)
        XCTAssertTrue(few.more)
        XCTAssertEqual(CopyDisk.list(root: root.path + "/missing").files, [])
    }

    // MARK: Texts

    /// VoiceOver reads a row as "main.rs, changed, 12 lines added, 3 removed".
    func testSpokenRow() throws {
        let main = FileRow(FileChange(path: "src/main.rs", kind: .changed, added: 12, removed: 3))
        XCTAssertEqual(FilesCopy.spokenEnglish(main), "main.rs, changed, 12 lines added, 3 removed")
        XCTAssertEqual(FilesCopy.spokenEnglish(FileRow(FileChange(path: "a.md", kind: .new, added: 1, removed: 0))),
                       "a.md, new, 1 line added")
        XCTAssertEqual(FilesCopy.spokenEnglish(FileRow(FileChange(path: "old.txt", kind: .deleted, added: 0, removed: 61))),
                       "old.txt, deleted, 61 lines removed")
        XCTAssertEqual(FilesCopy.spokenEnglish(FileRow(FileChange(path: "b.md", kind: .changed, added: 1, removed: 1))),
                       "b.md, changed, 1 line added, 1 removed")
        // No counts: the name and the mark.
        XCTAssertEqual(FilesCopy.spokenEnglish(FileRow(FileChange(path: "logo.png", kind: .changed, text: false))),
                       "logo.png, changed")
        XCTAssertEqual(FilesCopy.spokenEnglish(FileRow(path: "item.ts", mark: .same)), "item.ts, not changed")
        let rows = FileRows.rows(try doc(), filter: .changes)
        XCTAssertEqual(FilesCopy.spokenEnglish(try XCTUnwrap(rows.first { $0.path == "README.md" })),
                       "README.md, conflict, You changed this file after the agent started., 4 lines added, 1 removed")
        XCTAssertEqual(FilesCopy.spokenEnglish(try XCTUnwrap(rows.first { $0.path == "scripts/deploy.sh" })),
                       "deploy.sh, kept in the copy, 9 lines added")
        XCTAssertEqual(FilesCopy.spokenEnglish(try XCTUnwrap(rows.first { $0.path == "src/cart.ts" })),
                       "cart.ts, changed, 12 lines added, 3 removed, the agent is writing it")
    }

    func testSizesAndCounts() {
        XCTAssertEqual(FilesCopy.size(0).english, "0 bytes")
        XCTAssertEqual(FilesCopy.size(1).english, "1 byte")
        XCTAssertEqual(FilesCopy.size(812).english, "812 bytes")
        XCTAssertEqual(FilesCopy.size(4_100).english, "4 KB")
        XCTAssertEqual(FilesCopy.size(999_400).english, "999 KB")
        XCTAssertEqual(FilesCopy.size(999_600).english, "1.0 MB")
        XCTAssertEqual(FilesCopy.size(1_240_000).english, "1.2 MB")
        XCTAssertEqual(FilesCopy.size(1_284_000_000).english, "1.3 GB")
        XCTAssertEqual(FilesCopy.changes(1).english, "1 change")
        XCTAssertEqual(FilesCopy.changes(3).english, "3 changes")
        XCTAssertEqual(FilesCopy.conflicts(1).english, "1 conflict")
        XCTAssertEqual(FilesCopy.files(2).english, "2 files")
        XCTAssertEqual(FilesCopy.stat(FileChange(path: "a", kind: .changed, added: 12, removed: 3)), "+12 −3")
        XCTAssertEqual(FilesCopy.stat(FileChange(path: "a", kind: .new, added: 4, removed: 0)), "+4")
        XCTAssertNil(FilesCopy.stat(FileChange(path: "a", kind: .changed)))
        XCTAssertEqual(FilesCopy.emptyLine.english, "No changes yet. Your folder stays as it is.")
    }

    func testTheLineOfTheEntryBar() {
        XCTAssertEqual(FilesCopy.waiting(CopyCounts(conflicts: 2, ready: 5)).english,
                       "7 changes wait in the copy, 2 in conflict")
        XCTAssertEqual(FilesCopy.waiting(CopyCounts(conflicts: 1)).english, "1 conflict in the copy")
        XCTAssertEqual(FilesCopy.waiting(CopyCounts(ready: 1)).english, "1 change waits in the copy")
        XCTAssertEqual(FilesCopy.waiting(CopyCounts(ready: 3)).english, "3 changes wait in the copy")
        XCTAssertEqual(FilesCopy.waiting(CopyCounts(kept: 2)).english, "2 changes kept in the copy")
        XCTAssertEqual(FilesCopy.waiting(CopyCounts()).english, "The copy has no changes")
    }

    // MARK: The text diff

    func testLinesOfAText() {
        XCTAssertEqual(TextSniff.lines(""), [])
        XCTAssertEqual(TextSniff.lines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(TextSniff.lines("a\nb"), ["a", "b"])
        XCTAssertEqual(TextSniff.lines("a\r\n\r\nb\r\n"), ["a", "", "b"])
        XCTAssertEqual(TextSniff.lines("\n"), [""])
    }

    func testWhatCountsAsText() {
        XCTAssertTrue(TextSniff.isText(Data("let a = 1\n".utf8)))
        XCTAssertTrue(TextSniff.isText(Data("纸 ü\n".utf8)))
        XCTAssertTrue(TextSniff.isText(Data()))
        XCTAssertFalse(TextSniff.isText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertFalse(TextSniff.isText(Data([0xFF, 0xFE, 0x41])))
        XCTAssertFalse(TextSniff.isText(Data(count: 3)))
        XCTAssertFalse(TextSniff.isText(Data(repeating: 0x61, count: TextSniff.maxBytes + 1)))
    }

    func testDiffOfAChangedFile() {
        let diff = TextDiff(old: "one\ntwo\nthree\nfour\n", new: "one\n2\nthree\nfour\nfive\n")
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
        XCTAssertFalse(diff.coarse)
        XCTAssertEqual(diff.lines.map(\.kind), [.same, .removed, .added, .same, .same, .added])
        XCTAssertEqual(diff.lines.map(\.text), ["one", "two", "2", "three", "four", "five"])
        XCTAssertEqual(diff.lines.map(\.left), [1, 2, nil, 3, 4, nil])
        XCTAssertEqual(diff.lines.map(\.right), [1, nil, 2, 3, 4, 5])
        // Side by side: the old line stands next to the line that replaces it.
        let rows = diff.rows()
        XCTAssertEqual(rows.map(\.kind), [.same, .changed, .same, .same, .added])
        XCTAssertEqual(rows[1].left, DiffRow.Side(number: 2, text: "two"))
        XCTAssertEqual(rows[1].right, DiffRow.Side(number: 2, text: "2"))
        XCTAssertNil(rows[4].left)
        XCTAssertEqual(rows[4].right, DiffRow.Side(number: 5, text: "five"))
        XCTAssertEqual(rows.map(\.id), [0, 1, 2, 3, 4])
    }

    func testDiffOfNewDeletedAndEqualFiles() {
        let new = TextDiff(old: "", new: "a\nb\n")
        XCTAssertEqual([new.added, new.removed], [2, 0])
        XCTAssertEqual(new.rows().map(\.kind), [.added, .added])
        let deleted = TextDiff(old: "a\nb\nc\n", new: "")
        XCTAssertEqual([deleted.added, deleted.removed], [0, 3])
        XCTAssertEqual(deleted.rows().map(\.kind), [.removed, .removed, .removed])
        let equal = TextDiff(old: "a\nb\n", new: "a\nb\n")
        XCTAssertTrue(equal.isEmpty)
        XCTAssertEqual(equal.lines.count, 2)
        XCTAssertTrue(TextDiff(old: "", new: "").lines.isEmpty)
    }

    /// The diff is a shortest edit script: applying it to the old lines
    /// gives the new lines, and the counts are minimal for these cases.
    func testDiffRebuildsBothFiles() {
        let cases: [([String], [String], Int)] = [
            (["a", "b", "c", "a", "b", "b", "a"], ["c", "b", "a", "b", "a", "c"], 5),
            (["x"], ["y"], 2),
            (["a", "b", "c"], ["b"], 2),
            (["b"], ["a", "b", "c"], 2),
            (["a", "a", "a"], ["a", "a"], 1),
            ([], ["a"], 1),
            (["1", "2", "3", "4", "5", "6"], ["1", "x", "3", "4", "y", "6", "7"], 5),
        ]
        for (old, new, edits) in cases {
            let diff = TextDiff(old: old, new: new)
            XCTAssertEqual(diff.lines.filter { $0.kind != .added }.map(\.text), old, "\(old) -> \(new)")
            XCTAssertEqual(diff.lines.filter { $0.kind != .removed }.map(\.text), new, "\(old) -> \(new)")
            XCTAssertEqual(diff.added + diff.removed, edits, "\(old) -> \(new)")
            XCTAssertEqual(diff.lines.compactMap(\.left), Array(1...max(1, old.count)).prefix(old.count).map { $0 })
            XCTAssertEqual(diff.lines.compactMap(\.right), Array(1...max(1, new.count)).prefix(new.count).map { $0 })
            XCTAssertEqual(diff.lines.map(\.id), Array(0..<diff.lines.count))
        }
    }

    func testDiffOfTheFixtureFile() throws {
        let tree = Fixtures.root.appendingPathComponent("files-tree")
        let old = try String(contentsOf: tree.appendingPathComponent("original/src/cart.ts"), encoding: .utf8)
        let new = try String(contentsOf: tree.appendingPathComponent("copy/src/cart.ts"), encoding: .utf8)
        let diff = TextDiff(old: old, new: new)
        // The counts of src/cart.ts in changes.json.
        let change = try XCTUnwrap(try doc().change("src/cart.ts"))
        XCTAssertEqual(diff.added, change.added)
        XCTAssertEqual(diff.removed, change.removed)
        XCTAssertEqual(diff.lines.first?.text, #"import { Item } from "./item";"#)
        XCTAssertEqual(diff.lines.first?.kind, .same)
    }

    func testLongRunsOfSameLinesFold() {
        let old = (1...40).map { "line \($0)" }
        var new = old
        new[19] = "changed"
        let diff = TextDiff(old: old, new: new)
        let rows = diff.rows(context: 3)
        // 16 lines fold at the start, 3 show, the change, 3 show, 17 fold at the end.
        XCTAssertEqual(rows.map(\.kind), [.fold(16), .same, .same, .same, .changed, .same, .same, .same, .fold(17)])
        XCTAssertEqual(rows[1].left?.number, 17)
        XCTAssertEqual(rows.map(\.id), Array(0..<9))
        let unified = diff.unified(context: 3)
        XCTAssertEqual(unified.count, 10)
        XCTAssertTrue(TextDiff.isFold(unified[0]))
        XCTAssertEqual(unified[0].text, "16")
        XCTAssertFalse(TextDiff.isFold(unified[1]))
        XCTAssertEqual(unified.map(\.id), Array(0..<10))
        // A short run does not fold: a fold of one line saves nothing.
        let near = TextDiff(old: ["a", "b", "c", "d", "e", "f", "g", "h", "i"], new: ["A", "b", "c", "d", "e", "f", "g", "h", "I"])
        XCTAssertEqual(near.rows(context: 3).count, 9)
        XCTAssertEqual(diff.rows().count, 40)
        XCTAssertEqual(diff.unified().count, 41)
    }

    /// Two files with nothing in common, past the edit limit: every line
    /// of yours shows as removed and every line of the copy's as added.
    func testFarApartFilesGetACoarseDiff() {
        let old = (0..<1000).map { "old \($0)" }
        let new = (0..<1000).map { "new \($0)" }
        let diff = TextDiff(old: ["head"] + old + ["tail"], new: ["head"] + new + ["tail"])
        XCTAssertTrue(diff.coarse)
        XCTAssertEqual(diff.added, 1000)
        XCTAssertEqual(diff.removed, 1000)
        XCTAssertEqual(diff.lines.first?.kind, .same)
        XCTAssertEqual(diff.lines.last?.kind, .same)
        XCTAssertEqual(diff.lines.count, 2002)
        // A small change in a large file stays a line diff.
        var edited = old
        edited[500] = "edited"
        let small = TextDiff(old: old, new: edited)
        XCTAssertFalse(small.coarse)
        XCTAssertEqual([small.added, small.removed], [1, 1])
    }

    // MARK: The Apply sheet

    func testPlanListsWritesDeletesAndConflicts() throws {
        let plan = ApplyPlan(try doc())
        XCTAssertEqual(plan.run, "claude-1a2b3c")
        XCTAssertEqual(plan.token, "t-5f2c81aa")
        XCTAssertTrue(plan.all)
        XCTAssertEqual(plan.writes.map(\.path), ["assets/logo.png", "docs/notes.md", "src/cart.ts", "src/vendor/current"])
        XCTAssertEqual(plan.deletes.map(\.path), ["src/legacy/old-cart.ts"])
        XCTAssertEqual(plan.conflicts.map(\.path), ["README.md", "src/checkout.ts"])
        XCTAssertEqual(plan.left.map(\.path), ["scripts/deploy.sh"], "Apply All leaves a kept change in the copy")
        XCTAssertEqual(plan.writing.map(\.path), ["src/cart.ts"])
        XCTAssertEqual(plan.title.english, "Apply 7 changes to shop?")
    }

    /// Apply stays off until every conflict has a choice.
    func testApplyNeedsAChoiceForEveryConflict() throws {
        var plan = ApplyPlan(try doc())
        XCTAssertFalse(plan.canApply)
        XCTAssertEqual(plan.open.map(\.path), ["README.md", "src/checkout.ts"])
        plan.choose(.merge, for: "README.md")
        XCTAssertFalse(plan.canApply, "one conflict is still open")
        XCTAssertEqual(plan.open.map(\.path), ["src/checkout.ts"])
        plan.choose(.original, for: "src/checkout.ts")
        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.count, 6, "five ready changes and one merge; the file you keep is not touched")
        // The ready changes with the token, then the merge. The file you
        // keep needs no call.
        XCTAssertEqual(plan.calls, [
            ["apply", "claude-1a2b3c", "--on-conflict", "stop", "--yes", "--json", "--token", "t-5f2c81aa", "--",
             "assets/logo.png", "docs/notes.md", "src/cart.ts", "src/vendor/current", "src/legacy/old-cart.ts"],
            ["apply", "claude-1a2b3c", "--on-conflict", "merge", "--yes", "--json", "--", "README.md"],
        ])
        // A path that is no conflict takes no choice.
        plan.choose(.copy, for: "src/cart.ts")
        XCTAssertEqual(plan.choices.count, 2)
        plan.chooseAll(.copy)
        XCTAssertEqual(plan.choices, ["README.md": .copy, "src/checkout.ts": .copy])
        XCTAssertEqual(plan.count, 7)
    }

    func testPlanWithoutConflictsNamesNoPath() throws {
        var doc = try doc()
        doc.changes.removeAll { $0.isConflict }
        let plan = ApplyPlan(doc)
        XCTAssertTrue(plan.canApply)
        XCTAssertNil(plan.paths)
        XCTAssertEqual(plan.calls, [["apply", "claude-1a2b3c", "--on-conflict", "stop", "--yes", "--json", "--token", "t-5f2c81aa"]])
        XCTAssertEqual(plan.title.english, "Apply 5 changes to shop?")
        // Nothing to apply: Apply is off.
        XCTAssertFalse(ApplyPlan(try self.doc("changes-empty.json")).canApply)
        XCTAssertTrue(ApplyPlan(try self.doc("changes-empty.json")).isEmpty)
    }

    func testPlanForPickedFiles() throws {
        let plan = ApplyPlan(try doc(), paths: ["src/cart.ts", "scripts/deploy.sh"])
        XCTAssertFalse(plan.all)
        XCTAssertEqual(plan.writes.map(\.path), ["scripts/deploy.sh", "src/cart.ts"], "a kept file that you pick goes too")
        XCTAssertEqual(plan.left, [])
        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.calls, [["apply", "claude-1a2b3c", "--on-conflict", "stop", "--yes", "--json", "--token",
                                     "t-5f2c81aa", "--", "scripts/deploy.sh", "src/cart.ts"]])
        XCTAssertEqual(ApplyPlan(try doc(), paths: ["src/cart.ts"]).title.english, "Apply 1 change to shop?")
        var one = ApplyPlan(try doc(), paths: ["README.md"])
        XCTAssertFalse(one.canApply)
        one.choose(.copy, for: "README.md")
        XCTAssertTrue(one.canApply)
        XCTAssertEqual(one.calls, [["apply", "claude-1a2b3c", "--on-conflict", "copy", "--yes", "--json", "--token",
                                    "t-5f2c81aa", "--", "README.md"]], "only a conflict: its call carries the token")
    }

    /// The three choices of a conflict. A merge needs text on both sides.
    func testChoicesOfAConflict() throws {
        let doc = try doc()
        XCTAssertEqual(ApplyPlan.choices(for: doc.changes[0]), [.copy, .original, .merge])
        XCTAssertEqual(ApplyPlan.mergeNote(doc.changes[0])?.english, "Both sets of changes fit together.")
        XCTAssertEqual(ApplyPlan.mergeNote(doc.changes[5])?.english,
                       "Some lines changed on both sides: paddock marks them in the file.")
        let binary = FileChange(path: "a.png", kind: .changed, state: .conflict, copy: FileEntry(size: 1),
                                original: FileEntry(size: 2), text: false)
        XCTAssertEqual(ApplyPlan.choices(for: binary), [.copy, .original])
        let gone = FileChange(path: "a.ts", kind: .deleted, state: .conflict, original: FileEntry(size: 2), text: true)
        XCTAssertEqual(ApplyPlan.choices(for: gone), [.copy, .original], "the agent deleted it: nothing to merge")
        let link = FileChange(path: "l", kind: .changed, state: .conflict, copy: FileEntry(size: 1, link: "a"),
                              original: FileEntry(size: 1, link: "b"))
        XCTAssertEqual(ApplyPlan.choices(for: link), [.copy, .original])
        var plan = ApplyPlan(ChangesDoc(run: doc.run, pointer: doc.pointer, token: nil, counts: CopyCounts(),
                                        changes: [binary], applied: [], behind: [], special: [], autoApply: false))
        plan.choose(.merge, for: "a.png")
        XCTAssertFalse(plan.canApply, "a choice the conflict does not offer is no choice")
        plan.chooseAll(.merge)
        XCTAssertFalse(plan.canApply)
        XCTAssertEqual(ConflictChoice.allCases.map(\.title.english), ["Use the copy", "Keep mine", "Merge both"])
    }

    // MARK: Motion

    func testMotionOfAnApply() {
        XCTAssertEqual(ApplyMotion.seconds, 0.7)
        XCTAssertEqual(ApplyMotion.style(changes: 3, reduceMotion: false), .fly(parts: 3))
        XCTAssertEqual(ApplyMotion.style(changes: 40, reduceMotion: false), .fly(parts: 6))
        // With Reduce Motion, a check mark appears instead.
        XCTAssertEqual(ApplyMotion.style(changes: 3, reduceMotion: true), .check)
        XCTAssertEqual(ApplyMotion.style(changes: 3, reduceMotion: false, still: true), .check)
        XCTAssertEqual(ApplyMotion.style(changes: 0, reduceMotion: false), .check)
        // The model glows while changes wait.
        XCTAssertTrue(ApplyMotion.glows(CopyCounts(ready: 1)))
        XCTAssertTrue(ApplyMotion.glows(CopyCounts(conflicts: 1)))
        XCTAssertFalse(ApplyMotion.glows(CopyCounts(kept: 2, applied: 4)))
        XCTAssertFalse(ApplyMotion.glows(nil))
        XCTAssertEqual(ApplyMotion.delay(part: 0, of: 4), 0)
        XCTAssertEqual(ApplyMotion.delay(part: 3, of: 4), 0.7 / 3, accuracy: 0.0001)
        XCTAssertEqual(ApplyMotion.delay(part: 0, of: 1), 0)
    }

    // MARK: Backups

    func testTimelineByDay() throws {
        let doc = try BackupsDoc.decode(try Data(contentsOf: FilesContractTests.folder.appendingPathComponent("backups.json")))
        let days = BackupTimeline.days(doc, now: now, timeZone: utc)
        XCTAssertEqual(days.map(\.title.english), ["Today", "Yesterday", "30 Dec 2025"])
        XCTAssertEqual(days[0].points.map(\.id),
                       ["backup:b-20261106-0a1b2c", "backup:b-20261106-3d4e5f", "backup:b-20261106-6a7b8c"])
        // The snapshot of a direct run sits in the same timeline.
        XCTAssertEqual(days[1].points.map(\.id), ["backup:b-20261105-9d0e1f", "snapshot:aider-333333"])
        XCTAssertEqual(days[0].points.map(\.tag?.english), [nil, "Made by Undo", "Undone"])
        XCTAssertEqual(days[1].points.map(\.tag?.english), ["Whole folder", "Snapshot"])
        XCTAssertEqual(days[0].points[0].words, "before an apply")
        XCTAssertEqual(days[0].points[0].facts.map(\.english), ["1 file", "1 KB"])
        XCTAssertEqual(Set(days.map(\.id)).count, 3)
        // Another time zone moves a point to another day.
        // Another time zone moves the points to other days: at UTC+14 it is just after midnight.
        let east = BackupTimeline.days(doc, now: now, timeZone: TimeZone(identifier: "Pacific/Kiritimati")!)
        XCTAssertEqual(east.map(\.title.english), ["Yesterday", "5 Nov", "31 Dec 2025"])
        XCTAssertEqual(BackupTimeline.days(BackupsDoc(project: "/p", pointer: doc.pointer, backups: [], snapshots: []),
                                           now: now, timeZone: utc), [])
    }

    func testRestoreOfAPoint() throws {
        let doc = try BackupsDoc.decode(try Data(contentsOf: FilesContractTests.folder.appendingPathComponent("backups.json")))
        let days = BackupTimeline.days(doc, now: now, timeZone: utc)
        let backup = days[0].points[0]
        XCTAssertEqual(backup.restoreArgs(project: "/Users/demo/shop"),
                       ["restore", "b-20261106-0a1b2c", "--project", "/Users/demo/shop", "--yes", "--json"])
        XCTAssertTrue(backup.restoresOneFile)
        XCTAssertEqual(FilesArgs.restore("b-20261106-0a1b2c", paths: ["src/cart.ts"], project: "/Users/demo/shop"),
                       ["restore", "b-20261106-0a1b2c", "--project", "/Users/demo/shop", "--yes", "--json", "--", "src/cart.ts"])
        // A snapshot restores whole, with `paddock undo`.
        let snapshot = days[1].points[1]
        XCTAssertEqual(snapshot.restoreArgs(project: "/Users/demo/shop"), ["undo", "aider-333333", "--yes", "--json"])
        XCTAssertFalse(snapshot.restoresOneFile)
        XCTAssertEqual(BackupTimeline.restoreQuestion(backup, project: "/Users/demo/src/shop", timeZone: utc).english,
                       "Restore shop to 09:45?")
    }

    // MARK: The pointer

    func testPointerHasOneActionPerState() throws {
        func summary(_ name: String) throws -> PointerSummary {
            let doc = try PointerDoc.decode(try Data(contentsOf: FilesContractTests.folder.appendingPathComponent(name)))
            return PointerSummary(doc.part, doc: doc)
        }
        let ok = try summary("pointer.json")
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.chip.english, "Copies safe")
        XCTAssertEqual(ok.action, .reveal("/Users/demo/.local/share/paddock/copies/7c1d9e42"))
        XCTAssertEqual(ok.actionTitle.english, "Show in Finder")
        XCTAssertEqual(ok.size?.english, "1.3 GB")
        XCTAssertEqual(ok.encryptionWord.english, "Encrypted")
        XCTAssertEqual(ok.encryptionDetail, "FileVault is on for this disk.")
        XCTAssertNil(ok.advice)

        // paddock names a command for the state: that is the action.
        let moved = try summary("pointer-moved.json")
        XCTAssertFalse(moved.ok)
        XCTAssertEqual(moved.chip.english, "Copies need you")
        XCTAssertEqual(moved.action, .run(args: ["pointer", "adopt", "/Users/demo/src/shop"]))
        XCTAssertEqual(moved.actionTitle.english, "Repair")
        XCTAssertEqual(moved.text, "This folder moved. Its store still names the old place.")
        XCTAssertEqual(moved.encryptionWord.english, "Not encrypted")

        // No store yet: nothing to show in Finder, so the action reads again.
        let none = try summary("pointer-none.json")
        XCTAssertEqual(none.action, .check)
        XCTAssertEqual(none.actionTitle.english, "Check Again")
        XCTAssertNil(none.size)
        XCTAssertEqual(none.encryptionWord.english, "Not known")

        // Before the full status is read: the short part of the changes list.
        let part = PointerSummary(PointerPart(state: "locked", text: "Another paddock uses the store.",
                                              action: "Wait for the other run to end.", ok: false))
        XCTAssertEqual(part.action, .check)
        XCTAssertEqual(part.advice, "Wait for the other run to end.", "advice that is no command only shows")
    }

    // MARK: Command lines

    func testArgsOfTheReadsAndTheActions() {
        XCTAssertEqual(FilesArgs.copies, ["changes", "--json"])
        XCTAssertEqual(FilesArgs.changes("claude-1a2b3c"), ["changes", "claude-1a2b3c", "--json"])
        XCTAssertEqual(FilesArgs.backups(project: "/Users/demo/src/shop"), ["backups", "/Users/demo/src/shop", "--json"])
        XCTAssertEqual(FilesArgs.pointer(project: "/p"), ["pointer", "status", "/p", "--json"])
        XCTAssertEqual(FilesArgs.keep("r", paths: ["a", "b c"]), ["keep", "r", "--json", "--", "a", "b c"])
        XCTAssertEqual(FilesArgs.discard("r", paths: nil), ["discard", "r", "--yes", "--json"])
        // A file named like a flag is a path: it comes after `--`.
        XCTAssertEqual(FilesArgs.discard("r", paths: ["--json"]), ["discard", "r", "--yes", "--json", "--", "--json"])
        XCTAssertEqual(FilesArgs.undo("b-1"), ["undo", "b-1", "--yes", "--json"])
        XCTAssertEqual(FilesArgs.apply("r", paths: nil, token: nil), ["apply", "r", "--on-conflict", "stop", "--yes", "--json"])
    }

    func testCommandOfAnActionLine() {
        XCTAssertEqual(FilesArgs.command("paddock pointer adopt /Users/demo/src/shop"),
                       ["pointer", "adopt", "/Users/demo/src/shop"])
        XCTAssertEqual(FilesArgs.command("  paddock pointer adopt '/Users/demo/my shop' --yes "),
                       ["pointer", "adopt", "/Users/demo/my shop", "--yes"])
        XCTAssertEqual(FilesArgs.command(#"paddock pointer adopt "/a b" c\ d ''"#), ["pointer", "adopt", "/a b", "c d", ""])
        XCTAssertEqual(FilesArgs.command(#"paddock x 'it'\''s'"#), ["x", "it's"])
        // Advice, another program, shell syntax, an open quote: no command.
        XCTAssertNil(FilesArgs.command("Wait for the other run to end."))
        XCTAssertNil(FilesArgs.command("rm -rf /"))
        XCTAssertNil(FilesArgs.command("paddock"))
        XCTAssertNil(FilesArgs.command("paddock pointer adopt /a && rm -rf /"))
        XCTAssertNil(FilesArgs.command("paddock pointer adopt 'open"))
        XCTAssertNil(FilesArgs.command(""))
    }
}

/// The store of the Files screens against a replayed paddock.
@MainActor
final class FilesStoreTests: XCTestCase {
    struct Setup {
        let runner: ReplayRunner
        let store: FilesStore
        let clock: FakeClock
    }

    let project = "/Users/demo/src/shop"
    let run = "claude-1a2b3c"

    func file(_ name: String) throws -> Data {
        try Data(contentsOf: FilesContractTests.folder.appendingPathComponent(name))
    }

    /// The `files` scenario: the agents scenario with the copy commands.
    func make(_ scenario: String = "files") throws -> Setup {
        let clock = FakeClock(start: Date(timeIntervalSince1970: 1_793_959_200))
        let runner = try ReplayRunner.load(scenario: Fixtures.scenario(scenario), clock: clock)
        let service = CLIPaddockService(runner: runner)
        return Setup(runner: runner, store: FilesStore(service: { service }, clock: clock), clock: clock)
    }

    func lines(_ s: Setup) -> [String] { s.runner.calls.map(\.line) }

    func testCopiesListTheRunsWithACopy() async throws {
        let s = try make()
        XCTAssertFalse(s.store.copiesLoaded)
        await s.store.refreshCopies()
        XCTAssertTrue(s.store.copiesLoaded)
        XCTAssertTrue(s.store.supported)
        XCTAssertEqual(s.store.copies.map(\.id), ["claude-1a2b3c", "gemini-111111", "codex-4d5e6f", "grok-222222"])
        XCTAssertEqual(s.store.counts(run: run)?.waiting, 7)
        XCTAssertEqual(s.store.counts(run: "gemini-111111"), CopyCounts())
        XCTAssertNil(s.store.counts(run: "codex-4d5e6f"))
        XCTAssertNil(s.store.counts(run: "kimi-7a8b9c"), "a run with no copy")
        XCTAssertNil(s.store.counts(run: nil))
        XCTAssertEqual(lines(s), ["changes --json"])
    }

    /// paddock 0.2.3 has no `changes`: the Files entry stays away.
    func testAnOlderPaddockHasNoCopies() async throws {
        let s = try make("agents")
        await s.store.refreshCopies()
        XCTAssertFalse(s.store.supported)
        XCTAssertFalse(s.store.copiesLoaded)
        XCTAssertEqual(s.store.copies, [])
        XCTAssertNil(s.store.problem, "a missing command is no error on the screen")
    }

    /// One failed read after a good one keeps the list.
    func testAFailedReadKeepsTheList() async throws {
        let s = try make()
        await s.store.refreshCopies()
        s.runner.reset(prefix: "changes --json")
        s.runner.on(FilesArgs.copies, json: "", status: 1, stderr: "paddock: busy")
        await s.store.refreshCopies()
        XCTAssertTrue(s.store.supported)
        XCTAssertEqual(s.store.copies.count, 4)
    }

    func testLoadReadsTheChangesOfARun() async throws {
        let s = try make()
        let ok = await s.store.load(run: run)
        XCTAssertTrue(ok)
        XCTAssertEqual(s.store.docs[run]?.changes.count, 8)
        XCTAssertEqual(lines(s), ["changes claude-1a2b3c --json"])
        // The counts of an open run come from its own list.
        XCTAssertEqual(s.store.counts(run: run)?.conflicts, 2)
        // A run that paddock does not know: the problem shows, in a plain sentence.
        let missing = await s.store.load(run: "nobody-000000")
        XCTAssertFalse(missing)
        XCTAssertNotNil(s.store.problem)
        XCTAssertNil(s.store.docs["nobody-000000"])
    }

    func testAnAnswerInAnotherFormIsAPlainProblem() async throws {
        let s = try make()
        s.runner.on(FilesArgs.changes("x-1"), json: #"{"api_version":"paddock.changes/v2"}"#)
        let ok = await s.store.load(run: "x-1")
        XCTAssertFalse(ok)
        XCTAssertEqual(s.store.problem?.message, FilesStore.badAnswer)
        XCTAssertEqual(s.store.problem?.details, "api_version is paddock.changes/v2, not paddock.changes/v1")
        // A quiet read (the poll) shows nothing.
        s.store.problem = nil
        let quiet = await s.store.load(run: "x-1", quiet: true)
        XCTAssertFalse(quiet)
        XCTAssertNil(s.store.problem)
    }

    func testListingUsesTheCopyFolder() async throws {
        let s = try make()
        await s.store.load(run: run)
        let asked = Box()
        s.store.lister = { root in
            asked.set(root)
            return ([ListedFile(path: "package.json", size: 1)], true)
        }
        await s.store.loadListing(run: run)
        XCTAssertEqual(asked.value, "/Users/demo/.local/share/paddock/copies/7c1d9e42/runs/claude-1a2b3c/tree")
        XCTAssertEqual(s.store.listed[run]?.map(\.path), ["package.json"])
        XCTAssertTrue(s.store.listedMore.contains(run))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?
        func set(_ value: String) {
            lock.lock()
            text = value
            lock.unlock()
        }
        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
    }

    /// Apply: the command with the token and the choices, the list read
    /// again, the motion and the line with ⌘Z.
    func testApplyRunsThePlanAndReadsAgain() async throws {
        let s = try make()
        s.runner.reset(prefix: "changes claude-1a2b3c --json")
        try s.runner.on(FilesArgs.changes(run), file: FilesContractTests.folder.appendingPathComponent("changes.json"))
        try s.runner.on(FilesArgs.changes(run), file: FilesContractTests.folder.appendingPathComponent("changes-after-apply.json"))
        await s.store.load(run: run)
        var plan = ApplyPlan(try XCTUnwrap(s.store.docs[run]))
        // A conflict without a choice: nothing runs.
        let early = await s.store.apply(plan)
        XCTAssertFalse(early)
        XCTAssertEqual(s.runner.calls(startingWith: ["apply"]).count, 0)
        plan.choose(.copy, for: "README.md")
        plan.choose(.original, for: "src/checkout.ts")
        let done = await s.store.apply(plan)
        XCTAssertTrue(done)
        XCTAssertEqual(s.runner.calls(startingWith: ["apply"]).map(\.args), plan.calls)
        XCTAssertNil(s.store.working)
        XCTAssertNil(s.store.problem)
        // Two calls (the ready changes, then the copy of README.md), and the
        // replayed answer says 7 files for each: the line adds them up.
        XCTAssertEqual(s.store.flight, ApplyFlight(id: 1, run: run, changes: 14))
        XCTAssertEqual(s.store.toast?.text.english, "Applied 14 changes to shop. ⌘Z takes it back.")
        // What stays: the kept file and the conflict you left.
        XCTAssertEqual(s.store.docs[run]?.changes.map(\.path), ["scripts/deploy.sh", "src/checkout.ts"])
        XCTAssertEqual(s.store.docs[run]?.token, "t-9b0e44d1")
        // The backups are read, so ⌘Z knows its target.
        XCTAssertEqual(s.store.undoTarget(project: project)?.id, "b-20261106-0a1b2c")
        XCTAssertEqual(lines(s).suffix(3), ["changes claude-1a2b3c --json", "changes --json", "backups /Users/demo/src/shop --json"])
        // The line goes away by itself.
        await waitUntil { s.clock.sleeperCount == 1 }
        s.clock.advance(5)
        await waitUntil { s.store.toast == nil }
    }

    /// A stale token: a plain sentence, paddock's line under Details, and
    /// the list is read again.
    func testAStaleApplySaysSoAndReadsAgain() async throws {
        let s = try make("files-moved")
        await s.store.load(run: run)
        var plan = ApplyPlan(try XCTUnwrap(s.store.docs[run]))
        plan.chooseAll(.copy)
        let done = await s.store.apply(plan)
        XCTAssertFalse(done)
        XCTAssertEqual(s.store.problem?.message, FilesStore.stale)
        XCTAssertEqual(s.store.problem?.details,
                       "paddock: the copy changed since token t-5f2c81aa. Run `paddock changes claude-1a2b3c` again.")
        XCTAssertNil(s.store.flight, "nothing moved")
        XCTAssertNil(s.store.toast)
        XCTAssertNil(s.store.working)
        XCTAssertEqual(s.runner.calls(startingWith: ["changes", run]).count, 2)
    }

    func testKeepAndDiscard() async throws {
        let s = try make()
        await s.store.load(run: run)
        let kept = await s.store.keep(run: run, paths: ["src/cart.ts"])
        XCTAssertTrue(kept)
        XCTAssertEqual(s.runner.calls(startingWith: ["keep"]).map(\.line), ["keep claude-1a2b3c --json -- src/cart.ts"])
        XCTAssertEqual(s.store.toast?.text.english, "Kept 1 change in the copy")
        let none = await s.store.keep(run: run, paths: [])
        XCTAssertFalse(none)

        let dropped = await s.store.discard(run: run, paths: ["docs/notes.md"])
        XCTAssertTrue(dropped)
        XCTAssertEqual(s.runner.calls(startingWith: ["discard"]).map(\.line),
                       ["discard claude-1a2b3c --yes --json -- docs/notes.md"])
        XCTAssertEqual(s.store.toast?.text.english, "Discarded 1 change")
        // Discard All names no path.
        let all = await s.store.discard(run: run, paths: nil)
        XCTAssertTrue(all)
        XCTAssertEqual(s.runner.calls(startingWith: ["discard"]).last?.line, "discard claude-1a2b3c --yes --json")
        let empty = await s.store.discard(run: run, paths: [])
        XCTAssertFalse(empty, "an empty choice is not Discard All")
        XCTAssertEqual(s.runner.calls(startingWith: ["discard"]).count, 2)
        XCTAssertNil(s.store.flight, "only an apply moves parts to the house")
    }

    func testRestoreOfAPointAndOfOneFile() async throws {
        let s = try make()
        await s.store.openBackups(project: project)
        let doc = try XCTUnwrap(s.store.backups[project])
        let days = BackupTimeline.days(doc, now: s.clock.now(), timeZone: TimeZone(identifier: "UTC")!)
        let point = days[0].points[0]
        let whole = await s.store.restore(point, project: project)
        XCTAssertTrue(whole)
        XCTAssertEqual(s.runner.calls(startingWith: ["restore"]).map(\.line), ["restore b-20261106-0a1b2c --project \(project) --yes --json"])
        XCTAssertEqual(s.store.toast?.text.english, "Restored shop")
        let one = await s.store.restore(point, paths: ["src/cart.ts"], project: project, run: run)
        XCTAssertTrue(one)
        XCTAssertEqual(s.runner.calls(startingWith: ["restore"]).last?.line,
                       "restore b-20261106-0a1b2c --project \(project) --yes --json -- src/cart.ts")
        XCTAssertEqual(s.store.toast?.text.english, "Restored cart.ts")
        // A snapshot goes back with `paddock undo`.
        let snapshot = days[1].points[1]
        let back = await s.store.restore(snapshot, project: project)
        XCTAssertTrue(back)
        XCTAssertEqual(s.runner.calls(startingWith: ["undo"]).map(\.line), ["undo aider-333333 --yes --json"])
    }

    /// ⌘Z takes the newest apply back that paddock can undo.
    func testUndoTakesTheLastApplyBack() async throws {
        let s = try make()
        let done = await s.store.undoLastApply(project: project, run: run)
        XCTAssertTrue(done)
        XCTAssertEqual(lines(s).first, "backups /Users/demo/src/shop --json", "the store asks which apply is the last")
        XCTAssertEqual(s.runner.calls(startingWith: ["undo"]).map(\.line), ["undo b-20261106-0a1b2c --yes --json"])
        XCTAssertEqual(s.store.toast?.text.english, "Took the last apply back")
    }

    func testUndoWithNothingToUndo() async throws {
        let s = try make("files-moved")
        let done = await s.store.undoLastApply(project: project)
        XCTAssertFalse(done)
        XCTAssertEqual(s.runner.calls(startingWith: ["undo"]).count, 0)
        XCTAssertEqual(s.store.toast?.text.english, "Nothing to undo")
    }

    func testPointerStatusAndItsRepair() async throws {
        let s = try make("files-moved")
        let failed = await s.store.loadPointer(project: project)
        XCTAssertNil(failed)
        let part = PointerPart(state: "ok", text: "", ok: true)
        let summary = s.store.summary(project: project, part: part)
        XCTAssertFalse(summary.ok, "the full status wins over the short part")
        guard case .run(let args) = summary.action else { return XCTFail("no repair command") }
        let problem = await s.store.repairPointer(args: args, project: project)
        XCTAssertNil(problem)
        XCTAssertEqual(lines(s), ["pointer status /Users/demo/src/shop --json", "pointer adopt /Users/demo/src/shop",
                                  "pointer status /Users/demo/src/shop --json"])
        XCTAssertNil(s.store.working)
        // Before the status is read, the short part is all there is.
        XCTAssertTrue(s.store.summary(project: "/other", part: part).ok)
    }

    func testProblemSentences() {
        XCTAssertEqual(FilesStore.problem(CommandError.timedOut).message, PlainError.noAnswer)
        XCTAssertEqual(FilesStore.problem(CommandError.failed(status: 2, line: "error: unexpected argument '--take'")).message,
                       PlainError.oldPaddock)
        XCTAssertEqual(FilesStore.problem(CommandError.failed(status: 1, line: "paddock: token is out of date")).message,
                       FilesStore.stale)
        XCTAssertEqual(FilesStore.problem(CommandError.badJSON(output: "<html>")).details, "<html>")
        XCTAssertEqual(FilesStore.failureLine(CommandOutput(status: 1, stdout: Data(#"{"error":"no such run"}"#.utf8), stderr: "")),
                       "no such run")
        XCTAssertEqual(FilesStore.failureLine(CommandOutput(status: 1, stdout: Data(), stderr: "a\nb\n")), "b")
    }
}
