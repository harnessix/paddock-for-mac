import AppKit
import PaddockKit
import SwiftUI
import UniformTypeIdentifiers

// The Files screens of an agent run: what the agent changed in its copy
// of the project, and how the changes get to your folder.
//
//   FilesSupport   the store, the paths, the icons, the entry bar
//   FilesScreen    the three panes and the toolbar
//   ChangesTable   the folder tree and the table
//   FilePreview    the text diff and the image compare
//   ApplySheet     what an apply writes, and the conflicts
//   BackupsSheet   the timeline of the backups
//   PointerChip    the chip and its popover
//   ApplyStage     the model on the desk, the house and the motion

/// The one store of the Files screens. It asks paddock through the
/// service of the launcher store, so it follows `Check Again`.
@MainActor
enum FilesHub {
    /// The store of the Files screens. A check points it at its own paddock.
    static var store: FilesStore = {
        let store = FilesStore(service: { AppContainer.store.service })
        store.lister = { root in
            let folder = FilesPaths.debugRoot.map { $0 + "/copy" } ?? root
            return await Task.detached { CopyDisk.list(root: folder) }.value
        }
        return store
    }()

    /// The seconds between two reads while a room or a Files screen shows.
    static let pollSeconds: Double = 4
}

/// Where the two sides of a change are on the disk.
enum FilesPaths {
    /// A debug build can read both sides from a folder with `copy` and
    /// `original` in it, so a UI test shows a real diff.
    static var debugRoot: String? {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["PADDOCK_LAUNCHER_FILES_ROOT"], !root.isEmpty { return root }
        #endif
        return nil
    }

    static func copyRoot(_ run: CopyRun) -> String {
        debugRoot.map { $0 + "/copy" } ?? run.copy
    }

    static func originalRoot(_ run: CopyRun) -> String {
        debugRoot.map { $0 + "/original" } ?? run.project
    }

    static func url(_ root: String, _ path: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(path)
    }

    /// The file that Quick Look and "Show in Finder" open for a row: the
    /// copy's, or yours when the copy has none (a deleted file).
    static func best(_ row: FileRow, run: CopyRun) -> URL? {
        let copy = url(copyRoot(run), row.path)
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        let original = url(originalRoot(run), row.path)
        return FileManager.default.fileExists(atPath: original.path) ? original : nil
    }
}

/// The Finder icons of files by their extension, and of a folder.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if let image = cache[ext] { return image }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }

    static let folder: NSImage = NSWorkspace.shared.icon(for: .folder)

    static func isImage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }
}

/// A Finder icon at a small size. It only decorates.
@MainActor
struct FinderIcon: View {
    let image: NSImage
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The mark of a file: the symbol in its color, then the word.
@MainActor
struct MarkLabel: View {
    let mark: FileMark
    var font: Font = .body

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mark.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(mark.tint.color)
                .accessibilityHidden(true)
            Text(mark.word)
        }
        .font(font)
        .labelInk()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(mark.word))
    }
}

enum FilesText {
    /// What VoiceOver reads for a row: `main.rs, changed, 12 lines
    /// added, 3 removed`, in the language of the user.
    static func spoken(_ row: FileRow) -> String {
        FilesCopy.spoken(row).map(\.localized).joined(separator: UIText(", ").localized)
    }

    /// The age of a file for the Time column.
    static func time(_ date: Date?, now: Date) -> UIText? {
        date.map { Format.age(since: $0, now: now) }
    }
}

// MARK: - The entry of an agent room

extension View {
    /// The Files entry of an agent room: a bar under the room that says
    /// what waits in the copy of the run, and the Files screen in place
    /// of the room once it is open. A run with no copy shows nothing.
    @MainActor
    func filesEntry(_ room: AgentRoom) -> some View {
        modifier(FilesEntry(room: room))
    }
}

@MainActor
private struct FilesEntry: ViewModifier {
    let room: AgentRoom
    @State private var open = false
    private var files: FilesStore { FilesHub.store }

    func body(content: Content) -> some View {
        Group {
            if open, let run = room.runID, files.row(run: run) != nil || files.docs[run] != nil {
                FilesScreen(runID: run, room: room) { open = false }
                    .transition(Motion.enter)
            } else {
                content
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        FilesEntryBar(room: room) { open = true }
                    }
            }
        }
        .onChange(of: room.key) { open = false }
        // The copies change while an agent works: read them again every
        // few seconds while the room shows. An older paddock has no
        // copies: one failed read ends the loop.
        .task(id: room.runID) {
            while !Task.isCancelled {
                await files.refreshCopies()
                if !files.supported { return }
                if open, let run = room.runID, files.working == nil { await files.load(run: run, quiet: true) }
                try? await Task.sleep(nanoseconds: UInt64(FilesHub.pollSeconds * 1_000_000_000))
            }
        }
    }
}

/// The bar under an agent room: the model on the desk (it glows while
/// changes wait), what waits, and the button that opens the Files screen.
@MainActor
struct FilesEntryBar: View {
    let room: AgentRoom
    let open: () -> Void
    private var files: FilesStore { FilesHub.store }

    var body: some View {
        if let row = files.row(run: room.runID) {
            let counts = row.counts
            HStack(spacing: Space.m) {
                DeskModel(glows: ApplyMotion.glows(counts), size: 26)
                Text(line(row))
                    .font(.callout)
                    .labelInk()
                    .lineLimit(1)
                    .accessibilityIdentifier("files-entry-line")
                Spacer(minLength: Space.s)
                Button(action: open) {
                    Label("Files", systemImage: "folder")
                }
                .help(Text("See what the agent changed, and apply it to your folder"))
                .accessibilityIdentifier("files-open")
            }
            .padding(.horizontal, Space.page)
            .padding(.vertical, Space.s)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Files of the run"))
            .accessibilityIdentifier("files-entry")
        }
    }

    private func line(_ row: CopyRunRow) -> UIText {
        if row.run.state == .removed { return FilesCopy.removed }
        guard let counts = row.counts else { return UIText("The agent works on a copy of the project") }
        return FilesCopy.waiting(counts)
    }
}
