import AppKit
import PaddockKit
import SwiftUI

/// The pointer chip of the Files toolbar: whether the copies of the
/// project are safe in its store. A click opens the popover with the size
/// of the store, the encryption of its disk and the one action of the state.
@MainActor
struct PointerChip: View {
    let project: String
    /// The state in short, from the changes list.
    let part: PointerPart
    @State private var shown = false
    private var files: FilesStore { FilesHub.store }

    var body: some View {
        let summary = files.summary(project: project, part: part)
        Button {
            shown.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: summary.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summary.ok ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                Text(summary.chip)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .labelInk()
            .lineLimit(1)
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .quietCapsule()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(Text("Where the copies of this project live"))
        .accessibilityLabel(Text(summary.chip))
        .accessibilityIdentifier("files-pointer-chip")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            PointerPopover(project: project, part: part) { shown = false }
        }
    }
}

/// The popover of the chip: paddock's sentence about the state, the store
/// size, the encryption state, where the store is, and one action.
@MainActor
struct PointerPopover: View {
    let project: String
    let part: PointerPart
    let close: () -> Void
    @State private var loading = true
    @State private var problem: InlineProblem?
    private var files: FilesStore { FilesHub.store }

    var body: some View {
        let summary = files.summary(project: project, part: part)
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: summary.symbol)
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summary.ok ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.chip)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("pointer-title")
                    if !summary.text.isEmpty {
                        Text(verbatim: summary.text)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pointer-text")
                    }
                    if let advice = summary.advice {
                        Text(verbatim: advice)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.m, verticalSpacing: Space.s) {
                GridRow {
                    Text("Store size")
                    if let size = summary.size {
                        Text(size).monospacedDigit().accessibilityIdentifier("pointer-size")
                    } else if loading {
                        ProgressView().controlSize(.mini).accessibilityLabel(Text("Measuring"))
                    } else {
                        Text("No store yet")
                    }
                }
                GridRow {
                    Text("Encryption")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: summary.encryptionSymbol).accessibilityHidden(true)
                            Text(summary.encryptionWord)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pointer-encryption")
                        if let detail = summary.encryptionDetail {
                            Text(verbatim: detail).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let store = summary.store {
                    GridRow {
                        Text("Holds")
                        Text(UIText("%@, %@", UIText("%lld copies", store.copies), UIText("%lld backups", store.backups)))
                    }
                    GridRow {
                        Text("Location")
                        Text(verbatim: Format.tildePath(store.dir, home: NSHomeDirectory()))
                            .font(.callout.monospaced())
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let problem {
                InlineProblemView(problem, id: "pointer-problem")
            }
            if case .run(let args) = summary.action {
                // The command that Repair runs, as paddock named it.
                Text(verbatim: PaddockArgs.display(args))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pointer-command")
            }
            HStack {
                Spacer()
                if files.working == .pointer {
                    ProgressView().controlSize(.small).accessibilityLabel(Text("Working"))
                }
                Button {
                    act(summary.action)
                } label: {
                    Text(summary.actionTitle)
                }
                .disabled(files.working != nil)
                .accessibilityIdentifier("pointer-action")
            }
        }
        .labelInk()
        .padding(Space.l)
        .frame(width: 340, alignment: .leading)
        .task {
            problem = await files.loadPointer(project: project)
            loading = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Where the copies live"))
        .accessibilityIdentifier("pointer-popover")
    }

    /// The one action of the state: show the store, run paddock's
    /// repair, or read the state again.
    private func act(_ action: PointerSummary.Action) {
        switch action {
        case .reveal(let dir):
            SystemLinks.reveal(dir)
            close()
        case .run(let args):
            Task { problem = await files.repairPointer(args: args, project: project) }
        case .check:
            Task {
                loading = true
                problem = await files.loadPointer(project: project)
                loading = false
            }
        }
    }
}
