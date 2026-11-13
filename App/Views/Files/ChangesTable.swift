import AppKit
import PaddockKit
import SwiftUI

/// What a row or a folder can do: Apply to original, Keep in the copy and
/// Discard, each with the paths it is about.
@MainActor
struct FileActions {
    var apply: ([String]) -> Void
    var keep: ([String]) -> Void
    var discard: ([String]) -> Void
    var quickLook: (String) -> Void
    var reveal: (String) -> Void
    /// False while paddock works, or when the copy is gone.
    var enabled: Bool
}

/// The three actions as menu items, for a row, a folder or the selection.
@MainActor
struct FileActionItems: View {
    let paths: [String]
    let actions: FileActions

    var body: some View {
        Button("Apply to Original…") { actions.apply(paths) }
            .disabled(paths.isEmpty || !actions.enabled)
        Button("Keep in the Copy") { actions.keep(paths) }
            .disabled(paths.isEmpty || !actions.enabled)
        Button("Discard…", role: .destructive) { actions.discard(paths) }
            .disabled(paths.isEmpty || !actions.enabled)
    }
}

// MARK: - The folder tree

/// The folders of the project with the count of the changes in each.
/// The first row is the project: it shows every file. Every folder shows,
/// each under its parent: the tree of a change set is small, and nothing
/// in it should hide.
@MainActor
struct FolderTree: View {
    let root: FolderNode
    @Binding var selection: String?
    /// The paths of the changes in a folder and below it.
    let paths: (String) -> [String]
    let actions: FileActions

    /// A folder with its depth under the project.
    struct Item: Identifiable {
        let node: FolderNode
        let depth: Int
        var id: String { node.path }
    }

    /// The folders in the order of the tree: each one, then its folders.
    static func items(_ node: FolderNode, depth: Int = 0) -> [Item] {
        [Item(node: node, depth: depth)] + node.children.flatMap { items($0, depth: depth + 1) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(FolderTree.items(root)) { item in
                FileTreeRow(node: item.node, paths: paths, actions: actions)
                    .padding(.leading, CGFloat(item.depth) * 14)
                    .tag(item.node.path)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(Text("Folders"))
        .accessibilityIdentifier("files-tree")
    }
}

@MainActor
private struct FileTreeRow: View {
    let node: FolderNode
    let paths: (String) -> [String]
    let actions: FileActions

    var body: some View {
        HStack(spacing: Space.s) {
            FinderIcon(image: FileIcons.folder)
            Text(verbatim: node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Space.xs)
            if node.conflicts > 0 {
                Image(systemName: FileMark.conflict.symbol)
                    .font(.caption)
                    .foregroundStyle(FileMark.conflict.tint.color)
                    .accessibilityHidden(true)
            }
            if node.changes > 0 {
                Text(verbatim: String(node.changes))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .quietCapsule()
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { FileActionItems(paths: paths(node.path), actions: actions) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityIdentifier("files-folder-" + (node.path.isEmpty ? "root" : node.path))
    }

    /// `src, 4 changes, 1 conflict`.
    private var spoken: String {
        var parts = [node.name]
        if node.changes > 0 { parts.append(FilesCopy.changes(node.changes).localized) }
        if node.conflicts > 0 { parts.append(FilesCopy.conflicts(node.conflicts).localized) }
        return parts.joined(separator: UIText(", ").localized)
    }
}

// MARK: - The table

/// The files as a table: Name, Change, Size, Time. A click on a column
/// title sorts by it. Each row has the three actions in its menu.
@MainActor
struct ChangesTable: View {
    let rows: [FileRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<FileRow>]
    let now: Date
    let actions: FileActions

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { row in
                NameCell(row: row)
            }
            .width(min: 140, ideal: 240)
            TableColumn("Change", value: \.sortMark) { row in
                ChangeCell(row: row)
            }
            .width(min: 96, ideal: 128, max: 180)
            TableColumn("Size", value: \.sortSize) { row in
                Text(verbatim: row.size.map { FilesCopy.size($0).localized } ?? "—")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 56, ideal: 72, max: 100)
            TableColumn("Time", value: \.sortTime) { row in
                Text(verbatim: FilesText.time(row.time, now: now)?.localized ?? "—")
                    .lineLimit(1)
            }
            .width(min: 64, ideal: 84, max: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = rows.filter { ids.contains($0.id) }
            FileActionItems(paths: chosen.filter(\.isChange).map(\.path), actions: actions)
            if chosen.count == 1, let row = chosen.first {
                Divider()
                Button("Quick Look") { actions.quickLook(row.path) }
                Button("Show in Finder") { actions.reveal(row.path) }
            }
        } primaryAction: { ids in
            if let id = ids.first { actions.quickLook(id) }
        }
        // Space opens Quick Look while the table has the focus, as in Finder.
        .onKeyPress(.space) {
            guard selection.count == 1, let path = selection.first else { return .ignored }
            actions.quickLook(path)
            return .handled
        }
        .accessibilityLabel(Text("Files"))
        .accessibilityIdentifier("files-table")
    }
}

/// The name of a file with its Finder icon and, in small, its folder.
/// VoiceOver reads the whole row here: "main.rs, changed, 12 lines added,
/// 3 removed".
@MainActor
private struct NameCell: View {
    let row: FileRow

    var body: some View {
        HStack(spacing: 6) {
            FinderIcon(image: FileIcons.icon(row.path))
                .opacity(row.mark == .deleted ? 0.5 : 1)
            Text(verbatim: row.name)
                .strikethrough(row.mark == .deleted)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !row.folder.isEmpty {
                Text(verbatim: row.folder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if row.change?.writing == true {
                Image(systemName: "pencil.line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(Text("The agent is writing this file"))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: FilesText.spoken(row)))
        .accessibilityIdentifier("files-row-" + row.path)
    }
}

/// The mark of a row: the symbol and the word, then the line counts.
@MainActor
private struct ChangeCell: View {
    let row: FileRow

    var body: some View {
        if row.mark == .same {
            // A file that is the same on both sides has no mark.
            Color.clear.frame(height: 1).accessibilityHidden(true)
        } else {
            HStack(spacing: 5) {
                Image(systemName: row.mark.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(row.mark.tint.color)
                Text(row.mark.word)
                    .lineLimit(1)
                if let stat = row.change.flatMap(FilesCopy.stat) {
                    Text(verbatim: stat)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // The name cell reads the mark and the counts already.
            .accessibilityHidden(true)
        }
    }
}
