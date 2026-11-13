import XCTest
@testable import PaddockKit

/// The contract with the copy commands of paddock 0.2.4, from the core
/// file `src/copy/json.rs`.
///
/// The files of Fixtures/copy-v1 are written by hand from the shapes of
/// that file. Two checks hold them to it: each object has exactly the keys
/// that `json.rs` writes (`CopyKeys`), and each one decodes to the values
/// in the file. When the core changes a shape, change `CopyKeys`, the
/// fixture and the reader together.
final class FilesContractTests: XCTestCase {
    static let folder = Fixtures.root.appendingPathComponent("copy-v1")

    func data(_ name: String) throws -> Data {
        try Data(contentsOf: FilesContractTests.folder.appendingPathComponent(name))
    }

    func object(_ name: String) throws -> JSONFields {
        try XCTUnwrap(JSONFields(try StrictJSON.parse(try data(name))))
    }

    func keys(_ fields: JSONFields) -> Set<String> { Set(fields.fields.keys) }

    func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    /// 2026-11-06 10:00 UTC, the "now" of the fixtures.
    let now: Double = 1_793_959_200

    /// The files this test reads. A new file in the folder must get a case.
    static let covered: Set<String> = [
        "README.txt", "copies.json", "copies-after-apply.json", "changes.json", "changes-plain.json",
        "changes-empty.json", "changes-after-apply.json", "backups.json", "backups-empty.json", "pointer.json",
        "pointer-moved.json", "pointer-none.json", "apply.json", "keep.json", "discard.json", "restore.json",
        "undo.json", "apply-stale.err",
    ]

    func testEveryFileHasACase() throws {
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: FilesContractTests.folder.path))
        XCTAssertEqual(names, FilesContractTests.covered)
    }

    // MARK: The keys of json.rs

    func testApiVersions() {
        XCTAssertEqual(CopyAPI.copies, "paddock.copies/v1")
        XCTAssertEqual(CopyAPI.changes, "paddock.changes/v1")
        XCTAssertEqual(CopyAPI.backups, "paddock.backups/v1")
        XCTAssertEqual(CopyAPI.pointer, "paddock.pointer/v1")
        XCTAssertEqual(CopyAPI.apply, "paddock.apply/v1")
        XCTAssertEqual(CopyAPI.keep, "paddock.keep/v1")
        XCTAssertEqual(CopyAPI.discard, "paddock.discard/v1")
        XCTAssertEqual(CopyAPI.restore, "paddock.restore/v1")
        XCTAssertEqual(CopyAPI.undo, "paddock.undo/v1")
    }

    /// `run_doc`, `counts_doc` and the rows of `copies_doc`.
    func testCopiesHaveTheKeysOfTheContract() throws {
        for name in ["copies.json", "copies-after-apply.json"] {
            let top = try object(name)
            XCTAssertEqual(keys(top), CopyKeys.copiesDoc, name)
            XCTAssertEqual(top.string("api_version"), CopyAPI.copies)
            let rows = top.objects("runs")
            XCTAssertEqual(rows.count, 4)
            for row in rows {
                XCTAssertEqual(keys(row), CopyKeys.copiesRow, name)
                // The counts are an object, or null when paddock has none.
                if let counts = JSONFields(row.fields["counts"]) {
                    XCTAssertEqual(keys(counts), CopyKeys.counts, name)
                } else {
                    XCTAssertEqual(row.fields["counts"], .null, name)
                }
            }
        }
    }

    /// `changes_doc`, `change_doc`, `entry_doc` and `pointer_part`.
    func testChangesHaveTheKeysOfTheContract() throws {
        for name in ["changes.json", "changes-plain.json", "changes-empty.json", "changes-after-apply.json"] {
            let top = try object(name)
            XCTAssertEqual(keys(top), CopyKeys.changesDoc, name)
            XCTAssertEqual(top.string("api_version"), CopyAPI.changes)
            XCTAssertEqual(keys(try XCTUnwrap(JSONFields(top.fields["run"]))), CopyKeys.run, name)
            XCTAssertEqual(keys(try XCTUnwrap(JSONFields(top.fields["pointer"]))), CopyKeys.pointerPart, name)
            XCTAssertEqual(keys(try XCTUnwrap(JSONFields(top.fields["counts"]))), CopyKeys.counts, name)
            for change in top.objects("changes") {
                XCTAssertEqual(keys(change), CopyKeys.change, name)
                for side in ["copy", "original"] {
                    if let entry = JSONFields(change.fields[side]) {
                        XCTAssertEqual(keys(entry), CopyKeys.entry, name)
                    } else {
                        XCTAssertEqual(change.fields[side], .null, name)
                    }
                }
            }
        }
    }

    /// `backups_doc`, `backup_doc` and the snapshots.
    func testBackupsHaveTheKeysOfTheContract() throws {
        for name in ["backups.json", "backups-empty.json"] {
            let top = try object(name)
            XCTAssertEqual(keys(top), CopyKeys.backupsDoc, name)
            XCTAssertEqual(top.string("api_version"), CopyAPI.backups)
            XCTAssertEqual(keys(try XCTUnwrap(JSONFields(top.fields["pointer"]))), CopyKeys.pointerPart, name)
            for backup in top.objects("backups") { XCTAssertEqual(keys(backup), CopyKeys.backup, name) }
            for snapshot in top.objects("snapshots") {
                XCTAssertEqual(keys(snapshot), CopyKeys.snapshot, name)
                XCTAssertEqual(snapshot.string("kind"), "snapshot")
                XCTAssertEqual(snapshot.string("words"), "start of run, in the folder")
            }
        }
    }

    /// `pointer_doc` and `pointer_fields`.
    func testPointerHasTheKeysOfTheContract() throws {
        for name in ["pointer.json", "pointer-moved.json", "pointer-none.json"] {
            let top = try object(name)
            XCTAssertEqual(keys(top), CopyKeys.pointerDoc, name)
            XCTAssertEqual(top.string("api_version"), CopyAPI.pointer)
            if let pointer = JSONFields(top.fields["pointer"]) {
                XCTAssertEqual(keys(pointer), CopyKeys.pointerFile, name)
            } else {
                XCTAssertEqual(top.fields["pointer"], .null, name)
            }
            if let store = JSONFields(top.fields["store"]) {
                XCTAssertEqual(keys(store), CopyKeys.pointerStore, name)
                XCTAssertEqual(keys(try XCTUnwrap(JSONFields(store.fields["size"]))), CopyKeys.storeSize, name)
            } else {
                XCTAssertEqual(top.fields["store"], .null, name)
            }
        }
    }

    /// `result`: the body with its `api_version`; the run and the project
    /// when the action has a run; a body that is no object comes as `paths`.
    func testResultsHaveTheShapeOfTheContract() throws {
        let versions = ["apply.json": CopyAPI.apply, "keep.json": CopyAPI.keep, "discard.json": CopyAPI.discard,
                        "restore.json": CopyAPI.restore, "undo.json": CopyAPI.undo]
        for (name, api) in versions {
            let top = try object(name)
            XCTAssertEqual(top.string("api_version"), api, name)
            XCTAssertEqual(top.fields["run"] != nil, top.fields["project"] != nil, "\(name): run and project come together")
        }
        XCTAssertEqual(keys(try object("keep.json")), ["paths", "api_version", "run", "project"])
        XCTAssertEqual(keys(try object("discard.json")), ["paths", "api_version", "run", "project"])
    }

    // MARK: The values

    func testCopiesDecode() throws {
        let doc = try CopiesDoc.decode(try data("copies.json"))
        XCTAssertEqual(doc.runs.map(\.id), ["claude-1a2b3c", "gemini-111111", "codex-4d5e6f", "grok-222222"])
        let claude = doc.runs[0].run
        XCTAssertEqual(claude.short, "1a2b3c")
        XCTAssertEqual(claude.harness, "claude")
        XCTAssertEqual(claude.project, "/Users/demo/src/shop")
        XCTAssertEqual(claude.projectName, "shop")
        XCTAssertEqual(claude.copy, "/Users/demo/.local/share/paddock/copies/7c1d9e42/runs/claude-1a2b3c/tree")
        XCTAssertEqual(claude.state, .live)
        XCTAssertEqual(claude.started, date(now - 1200))
        XCTAssertNil(claude.ended)
        XCTAssertNil(claude.removed)
        XCTAssertEqual(claude.method, "clone")
        XCTAssertTrue(claude.shared)
        XCTAssertFalse(claude.inPlace)
        XCTAssertEqual(claude.git, .bool(true))
        XCTAssertEqual(claude.files, 412)
        XCTAssertEqual(claude.bytes, 18_400_321)
        XCTAssertEqual(claude.store, "7c1d9e42")
        XCTAssertEqual(claude.base, .null)
        XCTAssertEqual(claude.carried, .null)
        XCTAssertEqual(doc.runs[0].counts, CopyCounts(new: 2, changed: 5, deleted: 1, conflicts: 2, kept: 1, ready: 5,
                                                      applied: 1, behind: 1))
        XCTAssertEqual(doc.runs[0].counts?.total, 8)
        XCTAssertEqual(doc.runs[0].counts?.waiting, 7)

        let gemini = doc.runs[1]
        XCTAssertEqual(gemini.run.state, .ended)
        XCTAssertEqual(gemini.run.ended, date(now - 5400))
        XCTAssertEqual(gemini.counts, CopyCounts())
        // paddock could not read this copy: the counts are null.
        XCTAssertNil(doc.runs[2].counts)
        let grok = doc.runs[3].run
        XCTAssertEqual(grok.state, .removed)
        XCTAssertEqual(grok.removed, date(now - 1800))
        XCTAssertEqual(grok.project, "/Users/demo/src/docs")
    }

    func testChangesDecode() throws {
        let doc = try ChangesDoc.decode(try data("changes.json"))
        XCTAssertEqual(doc.run.id, "claude-1a2b3c")
        XCTAssertEqual(doc.pointer, PointerPart(state: "ok", text: "The copies of this project are in its store.",
                                                action: nil, ok: true, store: "7c1d9e42"))
        XCTAssertEqual(doc.token, "t-5f2c81aa")
        XCTAssertEqual(doc.counts, CopyCounts(new: 2, changed: 5, deleted: 1, conflicts: 2, kept: 1, ready: 5, applied: 1,
                                              behind: 1))
        XCTAssertEqual(doc.applied, ["src/price.ts"])
        XCTAssertEqual(doc.behind, ["package.json"])
        XCTAssertEqual(doc.special, [])
        XCTAssertFalse(doc.autoApply)
        XCTAssertEqual(doc.changes.map(\.path), [
            "README.md", "assets/logo.png", "docs/notes.md", "scripts/deploy.sh", "src/cart.ts", "src/checkout.ts",
            "src/legacy/old-cart.ts", "src/vendor/current",
        ])

        let readme = doc.changes[0]
        XCTAssertEqual(readme, FileChange(
            path: "README.md", kind: .changed, state: .conflict, conflict: "both_changed",
            conflictText: "You changed this file after the agent started.", kept: false, writing: false,
            copy: FileEntry(size: 1310, mtime: date(now - 300), mode: "0644", link: nil),
            original: FileEntry(size: 1262, mtime: date(now - 240), mode: "0644", link: nil),
            text: true, added: 4, removed: 1, merge: .clean))

        let logo = doc.changes[1]
        XCTAssertEqual(logo.kind, .changed)
        XCTAssertEqual(logo.state, .open)
        XCTAssertEqual(logo.text, false, "a binary file")
        XCTAssertNil(logo.added)
        XCTAssertNil(logo.removed)
        XCTAssertNil(logo.merge)

        let notes = doc.changes[2]
        XCTAssertEqual(notes.kind, .new)
        XCTAssertNil(notes.original, "a new file has no original")
        XCTAssertEqual(notes.copy?.size, 86)
        XCTAssertEqual(notes.added, 4)
        XCTAssertEqual(notes.removed, 0)

        let deploy = doc.changes[3]
        XCTAssertEqual(deploy.state, .kept)
        XCTAssertTrue(deploy.kept)
        XCTAssertEqual(deploy.copy?.mode, "0755")
        XCTAssertEqual(deploy.copy?.isExecutable, true)

        let cart = doc.changes[4]
        XCTAssertTrue(cart.writing)
        XCTAssertEqual(cart.added, 12)
        XCTAssertEqual(cart.removed, 3)
        XCTAssertEqual(cart.name, "cart.ts")
        XCTAssertEqual(cart.folder, "src")

        XCTAssertEqual(doc.changes[5].merge, .conflicts)

        let old = doc.changes[6]
        XCTAssertEqual(old.kind, .deleted)
        XCTAssertNil(old.copy, "a deleted file has no copy")
        XCTAssertEqual(old.original?.size, 1840)
        XCTAssertEqual(old.folder, "src/legacy")

        // A symlink: the target, and no time.
        let link = doc.changes[7]
        XCTAssertEqual(link.copy, FileEntry(size: 6, mtime: nil, mode: "0777", link: "v2.1.0"))
        XCTAssertEqual(link.original?.link, "v2.0.4")
    }

    /// Without the detail the line counts and the merge state are null.
    func testChangesWithoutDetailDecode() throws {
        let doc = try ChangesDoc.decode(try data("changes-plain.json"))
        XCTAssertEqual(doc.changes.count, 8)
        for change in doc.changes {
            XCTAssertNil(change.text)
            XCTAssertNil(change.added)
            XCTAssertNil(change.removed)
            XCTAssertNil(change.merge)
        }
        XCTAssertEqual(doc.changes[0].conflict, "both_changed", "the conflict is there without the detail")
    }

    func testEmptyChangesDecode() throws {
        let doc = try ChangesDoc.decode(try data("changes-empty.json"))
        XCTAssertEqual(doc.run.id, "gemini-111111")
        XCTAssertEqual(doc.run.state, .ended)
        XCTAssertEqual(doc.changes, [])
        XCTAssertEqual(doc.counts, CopyCounts())
        let after = try ChangesDoc.decode(try data("changes-after-apply.json"))
        XCTAssertEqual(after.changes.map(\.path), ["scripts/deploy.sh", "src/checkout.ts"])
        XCTAssertEqual(after.counts.applied, 7)
        XCTAssertEqual(after.token, "t-9b0e44d1")
        XCTAssertEqual(try CopiesDoc.decode(try data("copies-after-apply.json")).runs[0].counts, after.counts)
    }

    func testBackupsDecode() throws {
        let doc = try BackupsDoc.decode(try data("backups.json"))
        XCTAssertEqual(doc.project, "/Users/demo/src/shop")
        XCTAssertTrue(doc.pointer.ok)
        XCTAssertEqual(doc.backups.map(\.id), [
            "b-20261106-0a1b2c", "b-20261106-3d4e5f", "b-20261106-6a7b8c", "b-20261105-9d0e1f", "b-20251230-aa00bb",
        ])
        let first = doc.backups[0]
        XCTAssertEqual(first.short, "0a1b2c")
        XCTAssertEqual(first.kind, "apply")
        XCTAssertEqual(first.words, "before an apply")
        XCTAssertEqual(first.created, date(now - 900))
        XCTAssertEqual(first.run, "claude-1a2b3c")
        XCTAssertEqual(first.harness, "claude")
        XCTAssertEqual(first.files, 1)
        XCTAssertEqual(first.paths, 1)
        XCTAssertEqual(first.bytes, 1204)
        XCTAssertTrue(first.shared)
        XCTAssertEqual(first.method, "clone")
        XCTAssertFalse(first.full)
        XCTAssertFalse(first.undone)
        XCTAssertFalse(first.byUndo)
        XCTAssertTrue(first.undoable)
        XCTAssertTrue(doc.backups[1].byUndo)
        XCTAssertTrue(doc.backups[2].undone)
        XCTAssertFalse(doc.backups[2].undoable)
        XCTAssertTrue(doc.backups[3].full)
        XCTAssertNil(doc.backups[4].run, "a restore has no run")
        XCTAssertNil(doc.backups[4].harness)
        XCTAssertEqual(doc.undoTarget?.id, "b-20261106-0a1b2c")

        XCTAssertEqual(doc.snapshots.count, 1)
        let snapshot = doc.snapshots[0]
        XCTAssertEqual(snapshot.id, "aider-333333")
        XCTAssertEqual(snapshot.short, "333333")
        XCTAssertEqual(snapshot.words, "start of run, in the folder")
        XCTAssertEqual(snapshot.created, date(now - 86400 - 7200))
        XCTAssertEqual(snapshot.harness, "aider")
        XCTAssertEqual(snapshot.files, 412)
        XCTAssertEqual(snapshot.bytes, 18_400_321)
        XCTAssertTrue(snapshot.shared)

        let empty = try BackupsDoc.decode(try data("backups-empty.json"))
        XCTAssertEqual(empty.backups, [])
        XCTAssertEqual(empty.snapshots, [])
        XCTAssertNil(empty.undoTarget)
    }

    func testPointerDecodes() throws {
        let doc = try PointerDoc.decode(try data("pointer.json"))
        XCTAssertEqual(doc.project, "/Users/demo/src/shop")
        XCTAssertEqual(doc.part, PointerPart(state: "ok", text: "The copies of this project are in its store.",
                                             action: nil, ok: true, store: "7c1d9e42"))
        XCTAssertEqual(doc.pointer, PointerFile(format: "1", store: "7c1d9e42", created: date(now - 86400 * 40)))
        XCTAssertEqual(doc.store, PointerStore(
            id: "7c1d9e42", dir: "/Users/demo/.local/share/paddock/copies/7c1d9e42", original: "/Users/demo/src/shop",
            created: date(now - 86400 * 40), runs: 6, copies: 2, backups: 5, bytes: 1_284_000_000, sizeKind: "on_disk"))
        XCTAssertEqual(doc.encryption, .on(detail: "FileVault is on for this disk."))

        let moved = try PointerDoc.decode(try data("pointer-moved.json"))
        XCTAssertFalse(moved.part.ok)
        XCTAssertEqual(moved.part.state, "moved")
        XCTAssertEqual(moved.part.action, "paddock pointer adopt /Users/demo/src/shop")
        XCTAssertEqual(moved.store?.original, "/Users/demo/code/shop")
        XCTAssertEqual(moved.encryption, .off(detail: "This disk is not encrypted."))

        // No pointer, no store, no disk check: all three are null.
        let none = try PointerDoc.decode(try data("pointer-none.json"))
        XCTAssertNil(none.pointer)
        XCTAssertNil(none.store)
        XCTAssertEqual(none.encryption, .unknown(detail: nil))
        XCTAssertTrue(none.part.ok)
    }

    func testResultsDecode() throws {
        let apply = try CopyResult.decode(try data("apply.json"), CopyAPI.apply)
        XCTAssertEqual(apply.run, "claude-1a2b3c")
        XCTAssertEqual(apply.project, "/Users/demo/src/shop")
        XCTAssertEqual(apply.count("applied"), 7)
        XCTAssertEqual(apply.count("skipped"), 1, "a list counts by its length")
        XCTAssertEqual(apply.backup, "b-20261106-ffee00")
        // A body that is a list comes as `paths`.
        let keep = try CopyResult.decode(try data("keep.json"), CopyAPI.keep)
        XCTAssertEqual(keep.paths, ["src/cart.ts"])
        XCTAssertEqual(keep.count("kept", "paths"), 1)
        XCTAssertEqual(try CopyResult.decode(try data("discard.json"), CopyAPI.discard).paths, ["docs/notes.md"])
        // An action with no run has neither `run` nor `project`.
        let restore = try CopyResult.decode(try data("restore.json"), CopyAPI.restore)
        XCTAssertNil(restore.run)
        XCTAssertNil(restore.project)
        XCTAssertEqual(try CopyResult.decode(try data("undo.json"), CopyAPI.undo).count("restored"), 1)
    }

    // MARK: What the readers refuse

    func testAnotherApiVersionIsRefused() throws {
        XCTAssertThrowsError(try ChangesDoc.decode(try data("copies.json"))) { error in
            XCTAssertEqual(error as? CopyContractError,
                           CopyContractError("api_version is paddock.copies/v1, not paddock.changes/v1"))
        }
        XCTAssertThrowsError(try CopiesDoc.decode(Data(#"{"api_version":"paddock.copies/v2","runs":[]}"#.utf8)))
        XCTAssertThrowsError(try CopiesDoc.decode(Data(#"{"runs":[]}"#.utf8)))
        XCTAssertThrowsError(try CopyResult.decode(try data("apply.json"), CopyAPI.keep))
        XCTAssertThrowsError(try BackupsDoc.decode(try data("pointer.json")))
        XCTAssertThrowsError(try PointerDoc.decode(try data("backups.json")))
    }

    func testAnObjectWithoutItsIdentityIsRefused() {
        let run = #"{"api_version":"paddock.copies/v1","runs":[{"harness":"claude","project":"/p"}]}"#
        XCTAssertThrowsError(try CopiesDoc.decode(Data(run.utf8))) { error in
            XCTAssertEqual(error as? CopyContractError, CopyContractError("a run has no id"))
        }
        let change = #"{"api_version":"paddock.changes/v1","run":{"id":"a-1","project":"/p"},"changes":[{"kind":"new"}]}"#
        XCTAssertThrowsError(try ChangesDoc.decode(Data(change.utf8))) { error in
            XCTAssertEqual(error as? CopyContractError, CopyContractError("a change has no path"))
        }
        // A key twice is no JSON of paddock.
        let twice = #"{"api_version":"paddock.copies/v1","runs":[],"runs":[]}"#
        XCTAssertThrowsError(try CopiesDoc.decode(Data(twice.utf8)))
    }

    /// A word that this launcher does not know stays readable: the screen
    /// shows the change, it does not go away.
    func testUnknownWordsStay() throws {
        let text = #"""
        {"api_version":"paddock.changes/v1","run":{"id":"a-1","short":"1","harness":"x","project":"/p","copy":"/c",
        "state":"frozen","started":1,"ended":null,"removed":null,"method":"reflink","shared":true,"in_place":false,
        "git":null,"files":1,"bytes":1,"store":"s","base":null,"carried":null},
        "pointer":{"state":null,"text":"paddock: no such store","action":null,"ok":false,"store":null},
        "token":7,"counts":{"new":0,"changed":0,"deleted":0,"conflicts":0,"kept":0,"ready":0,"applied":0,"behind":0},
        "changes":[{"path":"a","kind":"renamed","state":"parked","conflict":null,"conflict_text":null,"kept":false,
        "writing":false,"copy":null,"original":null,"text":null,"added":null,"removed":null,"merge":"odd"}],
        "applied":[{"path":"b"}],"behind":[],"special":["dev/null"],"auto_apply":true}
        """#
        let doc = try ChangesDoc.decode(Data(text.utf8))
        XCTAssertEqual(doc.run.state, .other("frozen"))
        XCTAssertEqual(doc.pointer, PointerPart(state: nil, text: "paddock: no such store", ok: false))
        XCTAssertEqual(doc.token, "7", "a token that is a number goes back as its digits")
        XCTAssertEqual(doc.changes[0].kind, .other("renamed"))
        XCTAssertEqual(doc.changes[0].state, .other("parked"))
        XCTAssertNil(doc.changes[0].merge)
        XCTAssertEqual(FileMark.of(doc.changes[0]), .changed)
        XCTAssertEqual(doc.applied, ["b"], "a list of objects gives their paths")
        XCTAssertEqual(doc.special, ["dev/null"])
        XCTAssertTrue(doc.autoApply)
    }

    /// The disk check comes in more than one form.
    func testEncryptionForms() {
        XCTAssertEqual(StoreEncryption(.bool(true)), .on(detail: nil))
        XCTAssertEqual(StoreEncryption(.bool(false)), .off(detail: nil))
        XCTAssertEqual(StoreEncryption(.string("filevault")), .on(detail: nil))
        XCTAssertEqual(StoreEncryption(.string("none")), .off(detail: nil))
        XCTAssertEqual(StoreEncryption(.string("apfs sealed")), .unknown(detail: "apfs sealed"))
        XCTAssertEqual(StoreEncryption(.object(["state": .string("luks"), "text": .string("LUKS on /dev/sda2")])),
                       .on(detail: "LUKS on /dev/sda2"))
        XCTAssertEqual(StoreEncryption(.null), .unknown(detail: nil))
        XCTAssertEqual(StoreEncryption(nil), .unknown(detail: nil))
    }
}
