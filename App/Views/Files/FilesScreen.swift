import AppKit
import PaddockKit
import QuickLook
import SwiftUI

/// The sheets of the Files screen.
enum FilesSheet: Identifiable {
    case apply(ApplyPlan)
    case backups

    var id: String {
        switch self {
        case .apply(let plan): return "apply:" + (plan.paths ?? []).joined(separator: "\n")
        case .backups: return "backups"
        }
    }
}

/// A discard that waits for its confirmation: some paths, or all (nil).
struct DiscardRequest: Equatable {
    var paths: [String]?
    var count: Int
}

/// The Files screen of an agent run, in place of its room: the folder
/// tree with counts on the left, the table of the files in the middle and
/// the preview on the right. The toolbar has the filter, the search,
/// Apply All, Discard All, the backups and the pointer chip.
///
/// Keys: Space for Quick Look, ⌘↩ apply, ⌘K keep, ⌘⌫ discard, ⌘Z undo the
/// last apply.
@MainActor
struct FilesScreen: View {
    let runID: String
    let room: AgentRoom
    let close: () -> Void
    @State private var filter: FilesFilter = .changes
    @State private var search = ""
    @State private var folder: String? = ""
    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<FileRow>] = []
    @State private var sheet: FilesSheet?
    @State private var discard: DiscardRequest?
    @State private var quickLook: URL?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var files: FilesStore { FilesHub.store }

    private var doc: ChangesDoc? { files.docs[runID] }
    private var project: String { doc?.run.project ?? files.row(run: runID)?.run.project ?? room.project ?? "" }
    private var projectName: String { (project as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let doc {
                toolbar(doc)
                Divider()
            }
            if let problem = files.problem, sheet == nil {
                InlineProblemView(problem, id: "files-problem")
                    .padding(.horizontal, Space.page)
                    .padding(.vertical, Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ToastBar(toast: files.toast)
        }
        .animation(Motion.change(reduceMotion), value: files.toast)
        .background(shortcuts)
        .navigationTitle(Text(UIText("Files of %@", projectName)))
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .apply(let plan): ApplySheet(plan: plan)
            case .backups: BackupsSheet(project: project, doc: doc)
            }
        }
        .confirmationDialog(discardTitle,
                            isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }),
                            presenting: discard) { request in
            Button("Discard", role: .destructive) {
                Task {
                    if await files.discard(run: runID, paths: request.paths) { selection = [] }
                }
            }
            .accessibilityIdentifier("files-discard-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The agent's version of these files is deleted from the copy. Your folder stays as it is.")
        }
        .quickLookPreview($quickLook)
        .task(id: runID) {
            files.problem = nil
            await files.load(run: runID)
            // ⌘Z needs to know the last apply.
            if !project.isEmpty { await files.loadBackups(project: project) }
        }
        .task(id: filter) {
            if filter == .all { await files.loadListing(run: runID) }
        }
        .onChange(of: filter) { selection = [] }
        .onChange(of: doc?.changes.map(\.path)) { tidy() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(UIText("Files of %@", projectName)))
        .accessibilityIdentifier("files-screen")
    }

    // MARK: Rows

    /// The rows of the filter that match the search.
    private func matching(_ doc: ChangesDoc) -> [FileRow] {
        FileRows.search(FileRows.rows(doc, filter: filter, listed: files.listed[runID] ?? []), search)
    }

    private func shown(_ doc: ChangesDoc) -> [FileRow] {
        let rows = FileRows.inFolder(matching(doc), folder ?? "")
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    /// The selected rows that are changes: what the keys act on.
    private var selectedChanges: [String] {
        guard let doc else { return [] }
        return doc.changes.map(\.path).filter { selection.contains($0) }
    }

    private var canAct: Bool {
        files.working == nil && doc != nil && doc?.run.state != .removed
    }

    private var actions: FileActions {
        FileActions(apply: { apply($0) }, keep: { keep($0) }, discard: { askDiscard($0) },
                    quickLook: { showQuickLook($0) }, reveal: { reveal($0) }, enabled: canAct)
    }

    // MARK: Header and toolbar

    private var header: some View {
        HStack(alignment: .center, spacing: Space.l) {
            Button(action: close) {
                Label("Back", systemImage: "chevron.left")
            }
            .help(Text("Back to the agent (⌘[)"))
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityIdentifier("files-back")
            ApplyStage(counts: doc?.counts ?? files.counts(run: runID),
                       flight: files.flight?.run == runID ? files.flight : nil,
                       tint: room.scene(index: 0).tint)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(UIText("Files of %@", projectName))
                    .font(.title2.bold())
                    .labelInk()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("files-title")
                Text(subtitle)
                    .font(.callout)
                    .labelInk()
                    .lineLimit(1)
                    .accessibilityIdentifier("files-subtitle")
            }
            Spacer(minLength: Space.m)
            if let doc {
                PointerChip(project: doc.run.project, part: doc.pointer)
            }
            Button {
                sheet = .backups
            } label: {
                Label("Backups", systemImage: "clock.arrow.circlepath")
            }
            .disabled(project.isEmpty)
            .help(Text("What paddock saved before it changed your folder"))
            .accessibilityIdentifier("files-backups")
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.m)
    }

    /// `Claude Code · 7 changes wait in the copy, 2 in conflict`.
    private var subtitle: UIText {
        let agent = room.title
        guard let counts = doc?.counts ?? files.counts(run: runID) else {
            return UIText(key: "%@", args: [agent])
        }
        return UIText(key: "%@ · %@", args: [agent, FilesCopy.waiting(counts).localized])
    }

    private func toolbar(_ doc: ChangesDoc) -> some View {
        HStack(spacing: Space.m) {
            Picker(selection: $filter) {
                ForEach(FilesFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            } label: {
                Text("Show")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("files-filter")
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("files-search")
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear the search"))
                }
            }
            .labelInk()
            .padding(.horizontal, Space.s)
            .padding(.vertical, 4)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(minWidth: 110, idealWidth: 180, maxWidth: 220)
            Spacer(minLength: Space.s)
            if files.working != nil {
                ProgressView().controlSize(.small).accessibilityLabel(Text("Working"))
            }
            Button("Discard All…") { askDiscard(nil) }
                .disabled(!canAct || doc.changes.isEmpty)
                .help(Text("Delete every change from the copy"))
                .accessibilityIdentifier("files-discard-all")
            Button {
                sheet = .apply(ApplyPlan(doc))
            } label: {
                Label("Apply All…", systemImage: "arrow.down.doc.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canAct || ApplyPlan(doc).isEmpty)
            .help(Text("Put the changes into your folder"))
            .accessibilityIdentifier("files-apply-all")
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.s)
        .background(.bar)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let doc {
            if doc.run.state == .removed {
                PlainEmpty {
                    Label { Text("The copy is gone") } icon: { DecorativeSymbol(name: "shippingbox") }
                } description: {
                    Text(FilesCopy.removed)
                } actions: {
                    Button("Backups") { sheet = .backups }
                }
                .accessibilityIdentifier("files-removed")
            } else if doc.changes.isEmpty, filter != .all {
                // No changes yet. Your folder stays as it is.
                PlainEmpty {
                    Label { Text("No changes yet") } icon: { DeskModel(glows: false, size: 84) }
                } description: {
                    Text("Your folder stays as it is.")
                } actions: {
                    Button("Show All Files") { filter = .all }
                        .accessibilityIdentifier("files-show-all")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(FilesCopy.emptyLine))
                .accessibilityIdentifier("files-empty")
            } else {
                panes(doc)
            }
        } else if files.problem != nil {
            PlainEmpty {
                Label { Text("The changes did not load") } icon: { DecorativeSymbol(name: "exclamationmark.triangle") }
            } description: {
                Text("Try again in a moment.")
            } actions: {
                Button("Try Again") { Task { await files.load(run: runID) } }
                    .accessibilityIdentifier("files-try-again")
            }
        } else {
            ProgressView()
                .accessibilityLabel(Text("Reading the copy"))
        }
    }

    private func panes(_ doc: ChangesDoc) -> some View {
        let all = matching(doc)
        let rows = shown(doc)
        let chosen = rows.filter { selection.contains($0.id) }
        return HSplitView {
            FolderTree(root: FileRows.tree(all, root: doc.run.projectName), selection: $folder,
                       paths: { FileRows.changePaths(doc, in: $0) }, actions: actions)
                .frame(minWidth: 140, idealWidth: 180, maxWidth: 280)
            VStack(spacing: 0) {
                if rows.isEmpty {
                    PlainEmpty {
                        Label {
                            if filter == .conflicts && search.isEmpty { Text("No conflicts") } else { Text("Nothing here") }
                        } icon: {
                            DecorativeSymbol(name: filter == .conflicts && search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                        }
                    } description: {
                        Text(emptyLine)
                    } actions: {
                        EmptyView()
                    }
                    .accessibilityIdentifier("files-none")
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ChangesTable(rows: rows, selection: $selection, sortOrder: $sortOrder, now: context.date,
                                     actions: actions)
                    }
                }
                if filter == .all, files.listedMore.contains(runID) {
                    Divider()
                    Text(UIText("The copy has more files. The first %lld show.", CopyDisk.limit))
                        .font(.caption)
                        .labelInk()
                        .padding(Space.xs)
                }
            }
            .frame(minWidth: 280, idealWidth: 420)
            FilePreview(doc: doc, rows: chosen, actions: actions)
                .frame(minWidth: 260, idealWidth: 380)
        }
    }

    private var emptyLine: UIText {
        if !search.isEmpty { return FilesCopy.nothingFound }
        if filter == .conflicts { return FilesCopy.noConflicts }
        return UIText("This folder has no files to show.")
    }

    // MARK: Keys

    /// The keys of the screen, as buttons that do not show. A key that
    /// also edits text is off while the search field has the focus. Space
    /// (Quick Look) belongs to the table: see `ChangesTable`.
    private var shortcuts: some View {
        Group {
            Button("Apply to Original…") { apply(selectedChanges) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedChanges.isEmpty || !canAct)
            Button("Keep in the Copy") { keep(selectedChanges) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(selectedChanges.isEmpty || !canAct)
            Button("Discard…") { askDiscard(selectedChanges) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selectedChanges.isEmpty || !canAct || searchFocused)
            Button("Undo the Last Apply") { undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(files.working != nil || searchFocused || project.isEmpty)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    /// After the list changed: a selected file that left it is no longer
    /// selected, and a folder with nothing left gives way to the project.
    private func tidy() {
        guard let doc else { return }
        let all = matching(doc)
        let paths = Set(all.map(\.path))
        if !selection.isSubset(of: paths) { selection = selection.intersection(paths) }
        if let folder, !folder.isEmpty, FileRows.inFolder(all, folder).isEmpty { self.folder = "" }
    }

    private func apply(_ paths: [String]) {
        guard let doc, !paths.isEmpty, canAct else { return }
        sheet = .apply(ApplyPlan(doc, paths: paths))
    }

    private func keep(_ paths: [String]) {
        guard !paths.isEmpty, canAct else { return }
        Task { await files.keep(run: runID, paths: paths) }
    }

    /// Discard asks first: the agent's version of the files goes.
    private func askDiscard(_ paths: [String]?) {
        guard let doc, canAct else { return }
        if let paths {
            guard !paths.isEmpty else { return }
            discard = DiscardRequest(paths: paths, count: paths.count)
        } else {
            guard !doc.changes.isEmpty else { return }
            discard = DiscardRequest(paths: nil, count: doc.changes.count)
        }
    }

    private var discardTitle: Text {
        guard let discard else { return Text("Discard?") }
        if discard.paths == nil { return Text(UIText("Discard all %lld changes of the copy?", discard.count)) }
        if discard.count == 1, let path = discard.paths?.first {
            return Text(UIText("Discard the change of %@?", (path as NSString).lastPathComponent))
        }
        return Text(UIText("Discard %lld changes?", discard.count))
    }

    private func undo() {
        guard !project.isEmpty else { return }
        Task { await files.undoLastApply(project: project, run: runID) }
    }

    private func showQuickLook(_ path: String) {
        guard let doc, let row = shown(doc).first(where: { $0.path == path }) ?? matching(doc).first(where: { $0.path == path }) else {
            return
        }
        if quickLook != nil {
            // Space again closes the panel, as in Finder.
            quickLook = nil
        } else {
            quickLook = FilesPaths.best(row, run: doc.run)
        }
    }

    private func reveal(_ path: String) {
        guard let doc, let row = matching(doc).first(where: { $0.path == path }),
              let url = FilesPaths.best(row, run: doc.run) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
