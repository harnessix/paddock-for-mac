import PaddockKit
import SwiftUI

/// The network models of the apps, one per app for the life of the
/// launcher, so a tab switch keeps the loaded rules on screen.
@MainActor
enum NetworkModels {
    private static var models: [String: NetworkModel] = [:]

    static func model(for name: String, store: LauncherStore) -> NetworkModel {
        if let model = models[name] { return model }
        let model = NetworkModel(name: name, store: store)
        models[name] = model
        return model
    }
}

/// The `Network` part of the Grants tab: the mode, the rules table, and
/// Add, Edit and Remove.
@MainActor
struct NetworkRulesPane: View {
    let model: AppDetailModel
    let net: NetworkModel
    @State private var selection = Set<RuleRow.ID>()
    @State private var editor: RuleEditorTarget?
    @State private var removing: [RuleRow] = []
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            modeHeader
            if let problem = net.problem {
                NetProblemBanner(message: problem) { net.problem = nil }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Network"))
        .task { await net.loadRules(force: true) }
        .sheet(item: $editor) { target in
            RuleEditorSheet(net: net, target: target)
        }
        .confirmationDialog(Text(NetRuleCopy.removeTitle(removing)), isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                let rows = removing
                Task { await net.remove(rows) }
                selection = []
            }
            .accessibilityIdentifier("confirm-remove-rules")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app asks again the next time it reaches these servers.")
        }
    }

    private var modeHeader: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Picker("Network", selection: Binding(get: { model.networkMode },
                                                 set: { mode in Task { await model.setNetwork(mode) } })) {
                ForEach(NetworkMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .menuAuditAction()
            .accessibilityIdentifier("network-mode")
            if let text = model.status?.networkText {
                DetailedText(UIText.cli(text, else: NetworkCopy.modeNote(model.networkMode)))
                    .font(.callout)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.networkNote {
                Text(note).font(.callout).labelInk()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let empty = net.rules.isEmpty
        switch net.rulesState {
        case .loaded where empty:
            PlainEmpty {
                Label { Text("No rules yet") } icon: { DecorativeSymbol(name: "list.bullet.rectangle") }
            } description: {
                Text("When you answer a question about a server, the rule appears here. You can also add one yourself.")
            } actions: {
                Button("Add Rule…") { editor = .add(RuleDraft()) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("No rules yet"))
            .accessibilityIdentifier("rules-empty")
        case .idle, .loading, .offline, .needsNewerPaddock, .failed:
            if empty || net.rulesState == .offline || net.rulesState == .needsNewerPaddock {
                NetStateView(state: net.rulesState, subject: .rules) {
                    Task { await net.loadRules(force: true) }
                }
            } else {
                table
            }
        case .loaded:
            table
        }
    }

    private var table: some View {
        // Time left counts down without a reload.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            RulesTable(rows: net.rows(now: context.date), now: context.date, selection: $selection,
                       edit: { editor = .edit($0) },
                       denyInstead: { row in
                           var draft = RuleDraft(row: row)
                           draft.verdict = .deny
                           editor = .add(draft)
                       },
                       remove: askRemove)
        }
    }

    private var footer: some View {
        let rows = net.rows(now: Date()).filter { selection.contains($0.id) }
        let editable = rows.count == 1 && rows.first?.isProfile == false
        let removable = rows.contains { !$0.isProfile }
        return HStack {
            Button("Add Rule…") { editor = .add(RuleDraft()) }
                .accessibilityIdentifier("add-rule-button")
            Button("Edit…") { if let row = rows.first { editor = .edit(row) } }
                .disabled(!editable)
                .accessibilityIdentifier("edit-rule-button")
            Button("Remove…") { askRemove(rows) }
                .disabled(!removable)
                .accessibilityIdentifier("remove-rule-button")
            Spacer()
            if case .failed(let line) = net.rulesState, !net.rules.isEmpty {
                // A failed reload keeps the last list and says so.
                // One line next to the buttons: the plain sentence, with
                // paddock's own line as its tooltip.
                ProblemLine { Text(PlainError.problem(line).message).lineLimit(1) }
                    .help(Text(verbatim: line))
            }
            LiveLabel(label: .live)
        }
        .disabled(net.rulesState == .offline || net.rulesState == .needsNewerPaddock)
    }

    private func askRemove(_ rows: [RuleRow]) {
        removing = rows.filter { !$0.isProfile }
        confirmRemove = !removing.isEmpty
    }
}
