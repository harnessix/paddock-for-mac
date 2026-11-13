import PaddockKit
import SwiftUI

/// The card above the terminal of a failed run: what failed in plain
/// words, the next step, and its buttons. paddock's own line is under
/// "Details", never the message (`AgentFailure`).
@MainActor
struct AgentFailureCard: View {
    let failure: AgentFailure
    /// The buttons that make sense here: no "Open the Log" while the log
    /// shows under the card.
    let steps: [AgentFailure.Step]
    let act: (AgentFailure.Step) -> Void
    @State private var showsUpdate = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s) {
                Text(failure.message)
                    .font(.headline)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("agent-failure-message")
                Text(failure.next)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("agent-failure-next")
                if let code = failure.exitCode {
                    Text(UIText("Exit code %@", String(code)))
                        .font(.caption)
                        .labelInk()
                        .accessibilityIdentifier("agent-failure-exit")
                }
                if showsUpdate {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Run this command in Terminal, then start again:").font(.callout).labelInk()
                            .fixedSize(horizontal: false, vertical: true)
                        CopyField(command: AgentFailure.updateCommand)
                            .frame(maxWidth: 360)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("agent-failure-update")
                }
                // The buttons wrap under each other when the words are long.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s) { buttons }
                    VStack(alignment: .leading, spacing: Space.s) { buttons }
                }
                if let line = failure.line {
                    DetailsDisclosure(text: line)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietPanel()
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(failure.message))
        .accessibilityIdentifier("agent-failure")
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(Array(steps.enumerated()), id: \.element) { index, step in
            let button = Button {
                if step == .updatePaddock { showsUpdate = true }
                act(step)
            } label: {
                Text(step.title)
            }
            .accessibilityIdentifier("agent-failure-" + step.rawValue)
            if index == 0 {
                button.buttonStyle(.borderedProminent)
            } else {
                button
            }
        }
    }
}

/// The notes of a run on the Details tab: paddock's lines that `--quiet`
/// keeps out of the pane, one group per level with its symbol. A paddock
/// that gives no `run_notes` shows nothing here.
@MainActor
struct RunNotesSection: View {
    let notes: [RunNote]?

    var body: some View {
        let groups = RunNotes.grouped(notes)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Notes from paddock").font(.headline).labelInk().accessibilityAddTraits(.isHeader)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.xs) {
                            Image(systemName: group.level.symbol.name)
                                .foregroundStyle(group.level.symbol.tint.color)
                                .accessibilityHidden(true)
                            Text(group.level.title).font(.subheadline.bold()).labelInk()
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(Array(group.notes.enumerated()), id: \.offset) { _, note in
                            // paddock's words, as it wrote them.
                            Text(verbatim: note.text)
                                .font(.callout.monospaced())
                                .labelInk()
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, Space.l + Space.xs)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(Text(group.level.title))
                    .accessibilityIdentifier("agent-notes-" + group.level.rawValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .quietPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent-notes")
        }
    }
}
