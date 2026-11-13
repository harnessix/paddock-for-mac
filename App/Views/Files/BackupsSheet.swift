import AppKit
import PaddockKit
import SwiftUI

/// The Backups sheet: a timeline by day of what paddock saved before it
/// changed your folder. Each point restores whole, or one file of it.
@MainActor
struct BackupsSheet: View {
    let project: String
    /// The run of the Files screen: its applied files are the first
    /// offers of "Restore One File".
    let doc: ChangesDoc?
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var asking: TimelinePoint?
    private var files: FilesStore { FilesHub.store }

    private var name: String { (project as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(UIText("Backups of %@", name))
                        .font(.title3.bold())
                        .labelInk()
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("backups-title")
                    Text("paddock saves each file before it replaces or deletes it in your folder.")
                        .font(.callout)
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.page)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: Space.m) {
                if let problem = files.problem {
                    InlineProblemView(problem, id: "backups-problem")
                }
                Spacer()
                if files.working == .restore {
                    ProgressView().controlSize(.small).accessibilityLabel(Text("Restoring"))
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("backups-done")
            }
            .padding(Space.page)
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 380, idealHeight: 540, maxHeight: 700)
        .task {
            await files.openBackups(project: project)
            loaded = true
        }
        .confirmationDialog(asking.map { Text(BackupTimeline.restoreQuestion($0, project: project)) } ?? Text("Restore?"),
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            presenting: asking) { point in
            Button("Restore") { restore(point, paths: nil) }
                .accessibilityIdentifier("backup-restore-confirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(BackupTimeline.restoreNote)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(UIText("Backups of %@", name)))
        .accessibilityIdentifier("backups-sheet")
    }

    @ViewBuilder private var content: some View {
        if let backups = files.backups[project] {
            let days = BackupTimeline.days(backups, now: files.clock.now())
            if days.isEmpty {
                PlainEmpty {
                    Label { Text("No backups yet") } icon: { DecorativeSymbol(name: "clock.arrow.circlepath") }
                } description: {
                    Text("paddock makes one each time it changes your folder.")
                } actions: {
                    EmptyView()
                }
                .accessibilityIdentifier("backups-empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.l) {
                        ForEach(days) { day in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(day.title)
                                    .font(.headline)
                                    .labelInk()
                                    .padding(.bottom, Space.s)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(day.points) { point in
                                    BackupRow(point: point, last: point.id == day.points.last?.id,
                                              offers: offers(point), enabled: files.working == nil,
                                              restoreAll: { asking = point },
                                              restoreOne: { restore(point, paths: [$0]) },
                                              choose: { chooseFile(point) })
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(Text(day.title))
                            .accessibilityIdentifier("backups-day-" + day.id)
                        }
                    }
                    .padding(Space.page)
                }
                .accessibilityIdentifier("backups-timeline")
            }
        } else if loaded {
            PlainEmpty {
                Label { Text("The backups did not load") } icon: { DecorativeSymbol(name: "exclamationmark.triangle") }
            } description: {
                Text("Try again in a moment.")
            } actions: {
                Button("Try Again") { Task { await files.openBackups(project: project) } }
            }
        } else {
            ProgressView().accessibilityLabel(Text("Reading the backups"))
        }
    }

    /// The files that "Restore One File" names: the applied files of the
    /// run that the backup belongs to.
    private func offers(_ point: TimelinePoint) -> [String] {
        guard case .backup(let backup) = point.source, let doc, backup.run == doc.run.id else { return [] }
        return Array(doc.applied.prefix(20))
    }

    private func restore(_ point: TimelinePoint, paths: [String]?) {
        Task { await files.restore(point, paths: paths, project: project, run: doc?.run.id) }
    }

    /// Restore One File, Choose…: a file of your folder, by its path from
    /// the folder.
    private func chooseFile(_ point: TimelinePoint) {
        guard let path = FilePicker.file(in: project) else { return }
        restore(point, paths: [path])
    }
}

/// One point of the timeline: the rail with its symbol, the time, why
/// paddock made it, what is in it, and Restore.
@MainActor
private struct BackupRow: View {
    let point: TimelinePoint
    let last: Bool
    let offers: [String]
    let enabled: Bool
    let restoreAll: () -> Void
    let restoreOne: (String) -> Void
    let choose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            // The rail: the symbol of the point, and the line to the next.
            VStack(spacing: 2) {
                Image(systemName: point.symbol)
                    .font(.system(size: 17))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                if !last {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    if let created = point.created {
                        Text(verbatim: Format.clock(created))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text(verbatim: point.words)
                        .lineLimit(2)
                    if let tag = point.tag {
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .quietCapsule()
                    }
                }
                Text(verbatim: facts)
                    .font(.callout)
            }
            .labelInk()
            .padding(.bottom, Space.l)
            Spacer(minLength: Space.s)
            HStack(spacing: Space.s) {
                if point.restoresOneFile {
                    Menu {
                        ForEach(offers, id: \.self) { path in
                            Button { restoreOne(path) } label: { Text(verbatim: path) }
                        }
                        if !offers.isEmpty { Divider() }
                        Button("Choose a File…", action: choose)
                    } label: {
                        Text("One File")
                    }
                    .menuAuditAction()
                    .fixedSize()
                    .help(Text("Restore one file from this backup"))
                    .accessibilityIdentifier("backup-one-" + point.id)
                }
                Button("Restore…", action: restoreAll)
                    .help(Text("Bring your folder back to this point"))
                    .accessibilityIdentifier("backup-restore-" + point.id)
            }
            .controlSize(.small)
            .disabled(!enabled)
        }
        // The row is as high as its texts, so the rail reaches the next point.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityIdentifier(point.id)
    }

    /// `Claude Code · 1 file · 1 KB`.
    private var facts: String {
        var parts: [String] = []
        if let harness = point.harness { parts.append(AgentCharacter.title(harness)) }
        parts += point.facts.map(\.localized)
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        var parts: [String] = []
        if let created = point.created { parts.append(Format.clock(created)) }
        parts.append(point.words)
        if let tag = point.tag { parts.append(tag.localized) }
        parts.append(facts)
        return parts.joined(separator: UIText(", ").localized)
    }
}

/// The open panel of "Restore One File". A debug build takes the answer
/// from the environment, so a UI test never drives a system panel.
enum FilePicker {
    /// The path of the chosen file from `folder`, or nil when the panel
    /// was cancelled or the file is not in the folder.
    @MainActor
    static func file(in folder: String) -> String? {
        if let path = Pickers.override("PADDOCK_LAUNCHER_PICK_FILE") { return relative(path, to: folder) }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: folder)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Restore")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return relative(url.path, to: folder)
    }

    /// `src/cart.ts` for `/p/src/cart.ts` in `/p`. Nil outside the folder.
    static func relative(_ path: String, to folder: String) -> String? {
        let base = URL(fileURLWithPath: folder).standardizedFileURL.path
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix), full.count > prefix.count else { return nil }
        return String(full.dropFirst(prefix.count))
    }
}
