import PaddockKit
import SwiftUI

/// The Apply sheet: what the apply writes into your folder and what it
/// deletes there, then each conflict with its three choices. Apply stays
/// off until every conflict has a choice.
@MainActor
struct ApplySheet: View {
    @State var plan: ApplyPlan
    @Environment(\.dismiss) private var dismiss
    @State private var failure: InlineProblem?
    private var files: FilesStore { FilesHub.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if !plan.writing.isEmpty {
                        ProblemLine {
                            Text(plan.writing.count == 1
                                ? UIText("The agent is still writing 1 of these files. Its newest lines may be missing.")
                                : UIText("The agent is still writing %lld of these files. Their newest lines may be missing.",
                                         plan.writing.count))
                                .labelInk()
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("apply-writing")
                        }
                    }
                    if !plan.writes.isEmpty {
                        ApplyList(title: Text("Writes into your folder"), changes: plan.writes, id: "apply-writes")
                    }
                    if !plan.deletes.isEmpty {
                        ApplyList(title: Text("Deletes in your folder"), changes: plan.deletes, id: "apply-deletes")
                    }
                    if !plan.conflicts.isEmpty {
                        conflicts
                    }
                    if !plan.left.isEmpty {
                        Label {
                            Text(plan.left.count == 1 ? UIText("1 kept change stays in the copy.")
                                : UIText("%lld kept changes stay in the copy.", plan.left.count))
                        } icon: {
                            DecorativeSymbol(name: FileMark.kept.symbol)
                        }
                        .font(.callout)
                        .labelInk()
                        .accessibilityIdentifier("apply-left")
                    }
                }
                .padding(Space.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 320, idealHeight: 520, maxHeight: 680)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(plan.title))
        .accessibilityIdentifier("apply-sheet")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.l) {
            ApplyStage(counts: nil, flight: nil)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(plan.title)
                    .font(.title3.bold())
                    .labelInk()
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("apply-title")
                Text("paddock backs up each file it replaces or deletes. ⌘Z takes the apply back.")
                    .font(.callout)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.page)
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(title: Text("Conflicts"), count: plan.conflicts.count)
                Spacer()
                if plan.conflicts.count > 1 {
                    Menu {
                        ForEach(ConflictChoice.allCases) { choice in
                            Button {
                                plan.chooseAll(choice)
                            } label: {
                                Text(choice.title)
                            }
                        }
                    } label: {
                        Text("Choose for All")
                    }
                    .menuAuditAction()
                    .fixedSize()
                    .accessibilityIdentifier("conflict-choose-all")
                }
            }
            Text("Your folder changed in these files after the agent started. Choose what goes into your folder.")
                .font(.callout)
                .labelInk()
                .fixedSize(horizontal: false, vertical: true)
            ForEach(plan.conflicts) { change in
                ConflictCard(change: change, choice: plan.choices[change.path]) { choice in
                    plan.choose(choice, for: change.path)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Conflicts"))
        .accessibilityIdentifier("apply-conflicts")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let failure {
                InlineProblemView(failure, id: "apply-problem")
            }
            ForEach(Array(plan.calls.enumerated()), id: \.offset) { _, args in
                CommandEcho(args: args)
            }
            HStack(spacing: Space.m) {
                if !plan.open.isEmpty {
                    Text(plan.open.count == 1 ? UIText("Choose for 1 conflict to go on.")
                        : UIText("Choose for %lld conflicts to go on.", plan.open.count))
                        .font(.callout)
                        .labelInk()
                        .accessibilityIdentifier("apply-hint")
                }
                Spacer()
                if files.working == .apply {
                    ProgressView().controlSize(.small).accessibilityLabel(Text("Applying"))
                }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("apply-cancel")
                Button("Apply") {
                    Task {
                        failure = nil
                        if await files.apply(plan) {
                            dismiss()
                        } else {
                            failure = files.problem ?? InlineProblem(message: PlainError.generic)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!plan.canApply || files.working != nil)
                .accessibilityIdentifier("apply-confirm")
            }
        }
        .padding(Space.page)
    }
}

/// `Conflicts  2`: a section title with its count.
@MainActor
private struct SectionTitle: View {
    let title: Text
    let count: Int

    var body: some View {
        HStack(spacing: Space.s) {
            title.font(.headline).labelInk()
            Text(verbatim: String(count))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .labelInk()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .quietCapsule()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The files of one kind in the plan: the mark, the path, the line counts.
@MainActor
private struct ApplyList: View {
    let title: Text
    let changes: [FileChange]
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionTitle(title: title, count: changes.count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(changes) { change in
                    ApplyRow(change: change)
                    if change.id != changes.last?.id { Divider() }
                }
            }
            .padding(.horizontal, Space.m)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }
}

@MainActor
private struct ApplyRow: View {
    let change: FileChange

    var body: some View {
        let row = FileRow(change)
        HStack(spacing: Space.s) {
            Image(systemName: row.mark.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(row.mark.tint.color)
                .accessibilityHidden(true)
            FinderIcon(image: FileIcons.icon(change.path))
            Text(verbatim: change.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .labelInk()
            Spacer(minLength: Space.s)
            if let stat = FilesCopy.stat(change) {
                Text(verbatim: stat).font(.caption.monospacedDigit()).labelInk()
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: FilesText.spoken(row)))
        .accessibilityIdentifier("apply-row-" + change.path)
    }
}

/// One conflict: the file, paddock's sentence, and the three choices.
@MainActor
private struct ConflictCard: View {
    let change: FileChange
    let choice: ConflictChoice?
    let choose: (ConflictChoice) -> Void

    var body: some View {
        let offered = ApplyPlan.choices(for: change)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: FileMark.conflict.symbol)
                    .foregroundStyle(FileMark.conflict.tint.color)
                    .accessibilityHidden(true)
                FinderIcon(image: FileIcons.icon(change.path))
                Text(verbatim: change.path)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s)
                if let stat = FilesCopy.stat(change) {
                    Text(verbatim: stat).font(.caption.monospacedDigit())
                }
            }
            if let text = change.conflictText {
                Text(verbatim: text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s) {
                ForEach(ConflictChoice.allCases) { item in
                    ChoiceButton(title: item.title, selected: choice == item) { choose(item) }
                        .disabled(!offered.contains(item))
                        .accessibilityIdentifier("conflict-" + change.path + "-" + item.rawValue)
                }
            }
            if let choice {
                Text(choice == .merge ? (ApplyPlan.mergeNote(change) ?? choice.note) : choice.note)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("conflict-note-" + change.path)
            } else if !offered.contains(.merge) {
                Text("This file cannot be merged: choose one side.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = ApplyPlan.mergeNote(change) {
                Text(UIText("Merge: %@", note.localized))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .labelInk()
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: change.path))
        .accessibilityIdentifier("conflict-" + change.path)
    }
}

/// One of the three choices: the chosen one is the filled button.
@MainActor
private struct ChoiceButton: View {
    let title: UIText
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if selected {
                Button(action: action) {
                    Label { Text(title) } icon: { Image(systemName: "checkmark").accessibilityHidden(true) }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Text(title) }
                    .buttonStyle(.bordered)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
