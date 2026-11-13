import PaddockKit
import SwiftUI

/// What a network list shows: its loading text and its failure texts.
enum NetSubject {
    case rules, connections, clipboard

    var loading: UIText {
        switch self {
        case .rules: return UIText("Loading rules…")
        case .connections: return UIText("Loading connections…")
        case .clipboard: return UIText("Loading clipboard settings…")
        }
    }

    var failedTitle: UIText {
        switch self {
        case .rules: return UIText("The rules did not load")
        case .connections: return UIText("The connections did not load")
        case .clipboard: return UIText("The clipboard settings did not load")
        }
    }

    /// The feature of a newer paddock that this list is.
    var coming: ComingFeature {
        switch self {
        case .rules: return .rules
        case .connections: return .connections
        case .clipboard: return .clipboard
        }
    }
}

/// A list that this paddock cannot give yet, as one quiet line: what
/// shows here, and "Needs paddock 0.2.4". Never a page of "cannot", no
/// warning symbol and no command to copy.
@MainActor
struct ComingLine: View {
    let feature: ComingFeature

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            DecorativeSymbol(name: "clock")
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.promise)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
                Text(ComingFeature.needs)
                    .font(.caption)
                    .labelInk()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("net-update")
    }
}

/// The screen of a list that is not loaded: loading, paddock offline, or
/// paddock's error with `Try Again`. A list that needs a newer paddock is
/// no screen of its own: one quiet line at the top (`ComingLine`).
@MainActor
struct NetStateView: View {
    let state: NetLoad
    let subject: NetSubject
    let retry: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView { Text(subject.loading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("net-loading")
        case .offline:
            PlainEmpty {
                Label { Text("paddock is not reachable") } icon: { DecorativeSymbol(name: "bolt.horizontal.circle") }
            } description: {
                Text("paddock for Mac cannot run the paddock command. Check that paddock is installed, then check again.")
            } actions: {
                Button("Check Again", action: retry)
                    .accessibilityIdentifier("net-retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("paddock is not reachable"))
            .accessibilityIdentifier("net-offline")
        case .needsNewerPaddock:
            ComingLine(feature: subject.coming)
                .padding(Space.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .failed(let line):
            PlainEmpty {
                Label { Text(subject.failedTitle) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            } description: {
                // A plain sentence; paddock's own line is under Details.
                VStack(spacing: Space.s) {
                    Text(PlainError.problem(line).message)
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("net-error-line")
                    if let details = PlainError.problem(line).details {
                        DetailsDisclosure(text: details)
                    }
                }
            } actions: {
                Button("Try Again", action: retry)
                    .accessibilityIdentifier("net-retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(subject.failedTitle))
            .accessibilityIdentifier("net-failed")
        case .loaded:
            EmptyView()
        }
    }
}

/// The same states as one row of a Form section.
@MainActor
struct NetStateRow: View {
    let state: NetLoad
    let subject: NetSubject
    let retry: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: Space.s) {
                ProgressView().controlSize(.small)
                Text(subject.loading)
            }
            .accessibilityElement(children: .combine)
        case .offline:
            row(Text("paddock is not reachable"), action: Text("Check Again"))
        case .needsNewerPaddock:
            ComingLine(feature: subject.coming)
        case .failed(let line):
            // A plain sentence; paddock's own line is under Details.
            VStack(alignment: .leading, spacing: Space.xs) {
                row(Text(PlainError.problem(line).message), action: Text("Try Again"))
                if let details = PlainError.problem(line).details {
                    DetailsDisclosure(text: details)
                }
            }
        case .loaded:
            EmptyView()
        }
    }

    private func row(_ text: Text, action: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            ProblemLine { text.fixedSize(horizontal: false, vertical: true) }
            Spacer()
            Button(action: retry) { action }
                .accessibilityIdentifier("net-retry")
        }
    }
}

/// paddock's line after a failed change, above a list, with the command
/// to copy when the fix is in Terminal.
@MainActor
struct NetProblemBanner: View {
    let message: NetMessage
    let dismiss: () -> Void

    var body: some View {
        GroupBox {
            content.padding(Space.xs)
        }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        HStack(alignment: .top) {
            ProblemLine {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(message.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("net-problem")
                    if let command = message.command {
                        CopyField(command: command)
                    }
                }
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Close"))
            .help(Text("Close"))
        }
    }
}
