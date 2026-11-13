import AppKit
import PaddockKit
import SwiftUI

/// The room of one agent run: its header (the character, the agent, the
/// project, the state pill, Stop and Open in Terminal), the card of a
/// failed run, then the terminal pane when the launcher has one, or the
/// details: the state, the time, the project, the branch, the changed
/// files, the requests that wait and paddock's notes.
@MainActor
struct AgentDetailView: View {
    let key: String
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @State private var tab: Tab = .terminal

    enum Tab: Hashable {
        case terminal, details
    }

    var body: some View {
        if let room = agents.room(key) {
            VStack(spacing: 0) {
                AgentHeader(room: room)
                Divider()
                let terminal = room.paneID.flatMap { TerminalPanes.shared.terminal($0) }
                if let failure = AgentFailure.of(room, screen: terminal?.screenText) {
                    AgentFailureCard(failure: failure, steps: steps(failure, room: room, hasPane: terminal != nil)) { step in
                        act(step, room: room)
                    }
                }
                if let terminal {
                    Picker(selection: $tab) {
                        Text("Terminal").tag(Tab.terminal)
                        Text("Details").tag(Tab.details)
                    } label: {
                        Text("Show")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(.vertical, Space.s)
                    .accessibilityIdentifier("agent-tab")
                    if tab == .terminal {
                        TerminalPaneView(terminal: terminal)
                            .background(Color.black)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(Text(AgentCopy.title(room)))
                            .accessibilityIdentifier("agent-pane-" + room.key)
                    } else {
                        AgentDetails(room: room)
                    }
                } else {
                    AgentDetails(room: room)
                }
            }
            .navigationTitle(Text(AgentCopy.title(room)))
            // The files of the run's copy: App/Views/Files.
            .filesEntry(room)
        } else {
            PlainEmpty {
                Label { Text("This run is gone") } icon: { DecorativeSymbol(name: "moon.zzz") }
            } description: {
                Text("paddock no longer lists it.")
            } actions: {
                // Never a dead end: the other runs, or a new one.
                VStack(spacing: Space.m) {
                    Button("New Agent…") { router.sheet = .newAgent(folder: nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.binary.isUsable)
                        .accessibilityIdentifier("gone-new-agent")
                    Button("Show All Agents") { store.selection = .agents }
                        .accessibilityIdentifier("gone-show-agents")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("This run is gone"))
            .accessibilityIdentifier("agent-gone")
        }
    }

    /// The buttons of the card: "Open the Log" only where a log can open
    /// and does not show already.
    private func steps(_ failure: AgentFailure, room: AgentRoom, hasPane: Bool) -> [AgentFailure.Step] {
        failure.steps.filter { step in
            guard step == .openLog else { return true }
            if hasPane { return tab != .terminal }
            return room.runID != nil && store.binary.isUsable
        }
    }

    private func act(_ step: AgentFailure.Step, room: AgentRoom) {
        switch step {
        case .startAgain:
            // The same start again; a run that this launcher did not
            // start opens New Agent for its project.
            if let key = agents.startAgain(room) {
                store.selection = .agent(key)
            } else {
                router.sheet = .newAgent(folder: room.project)
            }
        case .openLog:
            if room.paneID.flatMap({ TerminalPanes.shared.terminal($0) }) != nil {
                tab = .terminal
            } else if let key = agents.reopen(room) {
                store.selection = .agent(key)
            }
        case .updatePaddock:
            // The card shows the command to copy.
            break
        case .showAgents:
            store.selection = .agents
        }
    }
}

/// The header of an agent room: the room with the character, the title,
/// the project path and the state, and the actions.
@MainActor
struct AgentHeader: View {
    let room: AgentRoom
    @Environment(AgentStore.self) private var agents
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @State private var handoffFailed = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            AgentStagedRoom(room: room, index: 0, side: 88, zoom: .target(room.key))
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(AgentCopy.title(room))
                    .font(.title2.bold())
                    .labelInk()
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("agent-title")
                if let project = room.project {
                    Text(verbatim: Format.tildePath(project, home: NSHomeDirectory()))
                        .font(.callout)
                        .labelInk()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: Space.xs) {
                    AgentStatePill(state: room.state, word: room.stateWord)
                        .accessibilityIdentifier("agent-state")
                    // Manual is the default: plain words, no tag.
                    if room.manual {
                        Text("Asks before each step").font(.caption).labelInk()
                            .accessibilityIdentifier("agent-manual")
                    } else if room.auto {
                        AutoTag()
                        Text("Works on its own").font(.caption).labelInk()
                            .accessibilityIdentifier("agent-auto")
                    }
                }
            }
            Spacer(minLength: Space.m)
            VStack(alignment: .trailing, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    if let id = room.runID, room.state.isLive {
                        Button("Open in Terminal") {
                            handoffFailed = !TerminalHandoffAction.open(runID: id)
                        }
                        .help(Text("Hand the run to Terminal: paddock view --write"))
                        .accessibilityIdentifier("agent-open-terminal")
                    }
                    if room.runID != nil, room.state.isLive, !room.paneRunning {
                        Button("Reopen") {
                            if let key = agents.reopen(room) { store.selection = .agent(key) }
                        }
                        .accessibilityIdentifier("agent-reopen")
                    }
                    if room.canStop {
                        Button("Stop…") { router.sheet = .confirmStopAgent(room.key) }
                            .accessibilityIdentifier("agent-stop")
                    } else if let pane = room.paneID {
                        Button("Close") {
                            agents.close(pane)
                            TerminalPanes.shared.remove(pane)
                            store.selection = .agents
                        }
                        .accessibilityIdentifier("agent-close")
                    }
                }
                if handoffFailed {
                    ProblemLine { Text("Terminal did not open.").font(.caption) }
                }
                if let error = agents.lastError {
                    // A plain sentence; paddock's own line is under Details.
                    ProblemLine {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("agent-error")
                            if let details = agents.lastErrorDetails { DetailsDisclosure(text: details) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AgentCopy.spokenText(room)))
        .accessibilityIdentifier("agent-header")
    }
}

/// The details of a run: what paddock says about it, and its requests.
@MainActor
struct AgentDetails: View {
    let room: AgentRoom
    @Environment(AgentStore.self) private var agents

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if !room.requests.isEmpty {
                    VStack(alignment: .leading, spacing: Space.m) {
                        Text("Requests").font(.headline).labelInk().accessibilityAddTraits(.isHeader)
                        ForEach(room.requests) { request in
                            AgentRequestCard(request: request)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        LabeledContent {
                            Text(time(now: context.date))
                        } label: {
                            Text("Time")
                        }
                    }
                    // A fact shows when paddock gave it: no row with a dash.
                    if let project = room.project {
                        LabeledContent {
                            Text(verbatim: Format.tildePath(project, home: NSHomeDirectory()))
                                .lineLimit(1).truncationMode(.middle)
                        } label: {
                            Text("Project")
                        }
                    }
                    if let branch = room.branch {
                        LabeledContent { Text(verbatim: branch) } label: { Text("Branch") }
                    }
                    LabeledContent {
                        Text(AgentCopy.files(room.filesChanged))
                            .accessibilityIdentifier("agent-files")
                    } label: {
                        Text("Files changed")
                    }
                    if let files = room.files, !files.isEmpty {
                        ForEach(files, id: \.self) { file in
                            Text(verbatim: file).font(.callout.monospaced()).labelInk()
                        }
                    }
                    if let network = room.network {
                        LabeledContent { DetailedText(AgentNetwork.text(network)) } label: { Text("Network") }
                    }
                    if let activity = room.activity {
                        LabeledContent {
                            Text(verbatim: activity).font(.callout.monospaced()).lineLimit(2)
                        } label: {
                            Text("Last line")
                        }
                    }
                    if let device = room.device {
                        // The cable of the device calls: a spark per call.
                        LabeledContent {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(deviceLine(device)).accessibilityIdentifier("agent-device")
                                PlumbingCable(device: device.world).frame(maxWidth: 240)
                            }
                        } label: {
                            Text("Device")
                        }
                    }
                    if let id = room.runID {
                        LabeledContent { Text(verbatim: id).textSelection(.enabled) } label: { Text("Run") }
                    }
                }
                .labelInk()
                .frame(maxWidth: .infinity, alignment: .leading)
                .quietPanel()
                RunNotesSection(notes: room.notes)
            }
            .padding(Space.page)
        }
        .accessibilityIdentifier("agent-details")
    }

    /// `camera · Waits for your answer`, `camera · 3 calls`.
    private func deviceLine(_ device: DeviceCalls) -> UIText {
        let state = device.covered ? UIText("Waits for your answer")
            : device.calls == 1 ? UIText("1 call") : UIText("%lld calls", device.calls)
        guard let name = device.device else { return state }
        return UIText.list([UIText.verbatim(name), state])
    }

    /// `Running for 12 min`, `Ran for 2 h 5 min`, or `—`.
    private func time(now: Date) -> UIText {
        guard let started = room.started else { return UIText("Not known") }
        if let ended = room.ended { return UIText("Ran for %@", AgentCopy.duration(from: started, to: ended)) }
        if room.state.isLive { return UIText("Running for %@", AgentCopy.duration(from: started, to: now)) }
        return UIText("Started %@", Format.age(since: started, now: now))
    }
}

/// Stop an agent: the confirmation of ⌘. and the Stop buttons.
@MainActor
struct ConfirmStopAgentSheet: View {
    let key: String
    @Environment(AgentStore.self) private var agents

    var body: some View {
        if let room = agents.room(key) {
            ConfirmLayout(title: Text(UIText("Stop %@?", AgentCopy.title(room))),
                          message: Text("The agent stops at once. Its work in the project folder stays."),
                          action: Text("Stop"), destructive: false) {
                _ = await agents.stop(room)
            }
        } else {
            // The run went while the sheet was open: nothing to stop.
            ConfirmLayout(title: Text("This run is gone"), message: nil, action: Text("Close"), destructive: false) {}
        }
    }
}
