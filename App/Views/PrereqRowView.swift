import AppKit
import PaddockKit
import SwiftUI

/// One row of a checklist: the check, its result under it, a command to
/// copy and the buttons of a failed row, and the result symbol at the end.
/// The welcome window and the base image step show the same row.
@MainActor
struct PrereqRowView: View {
    let row: PrereqRow
    /// True while a check runs: Check again is off.
    let checking: Bool
    let checkAgain: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(row.title).font(.headline).labelInk()
                DetailedText(row.result).labelInk()
                if let command = row.command { CopyField(command: command) }
                HStack { ForEach(row.actions, id: \.self) { action in actionButton(action) } }
            }
            Spacer(minLength: Space.s)
            if row.status == .checking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text(row.accessibilityLabel))
            } else {
                StatusSymbol(name: row.symbol, tint: row.tint, label: row.accessibilityLabel)
                    .font(.title3)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prereq-" + row.id)
    }

    @ViewBuilder
    private func actionButton(_ action: PrereqRow.Action) -> some View {
        switch action {
        case .quit: Button("Quit") { NSApp.terminate(nil) }
        case .updateMacOS: Button("Update macOS in System Settings") { SystemLinks.open(SystemLinks.softwareUpdate) }
        case .copyInstall, .copyUpgrade: EmptyView()
        case .manageStorage: Button("Manage Storage…") { SystemLinks.manageStorage() }
        case .checkAgain:
            Button("Check again", action: checkAgain)
                .disabled(checking)
                .accessibilityIdentifier("check-again")
        }
    }
}
