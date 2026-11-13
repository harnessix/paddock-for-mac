import AppKit
import PaddockKit
import SwiftUI

/// The welcome window: three steps, numbered on the left, content on the
/// right. Welcome, Check this Mac, Start your first agent. Back and
/// Continue are bottom right; Quit is bottom left on step 1, and "Skip for
/// now" on step 3.
///
/// The flow leads to the first agent at work. Its story is that your
/// computer stays yours: step 1 says so, and step 3 lists "Ask me before
/// each step" first. It never asks for a permission, and nothing in it is about the virtual machines of the Mac
/// apps: those have their own step in the Apps section.
@MainActor
struct OnboardingView: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(UIRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True while Check again runs.
    @State private var checking = false
    /// The free space of the disk of the home folder.
    @State private var free: Int64?
    /// Step 3: the same form as the New Agent sheet.
    @State private var form = AgentForm(harnesses: [], recents: [])
    @State private var formLoaded = false
    @State private var dropTargeted = false

    private var step: WelcomeStep { WelcomeStep.at(router.welcomeStep) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                stepList
                    .frame(width: 190)
                    .padding(.top, Space.xxl)
                Divider()
                if step == .start {
                    // A grouped Form scrolls by itself.
                    startStep
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Space.s)
                } else {
                    // A new step fades in from the top of its page.
                    ScrollView {
                        content
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.xxl)
                            .id(step)
                            .transition(Motion.enter)
                    }
                    .animation(Motion.change(reduceMotion), value: step)
                }
            }
            Divider()
            footer.padding(Space.l)
        }
        .onAppear {
            AppContainer.openWindow = openWindow
        }
        // Again when the binary check ends: a look that ran before it saw
        // this Mac without paddock.
        .task(id: StepTrigger(step: step, usable: store.binary.isUsable)) {
            switch step {
            case .welcome: break
            case .check: await check()
            case .start: await loadForm()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tracksWindowVisibility()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Welcome to paddock"))
    }

    // MARK: Steps list

    private var stepList: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(WelcomeStep.allCases, id: \.self) { item in
                let index = item.rawValue
                let current = step.rawValue
                HStack(spacing: Space.s) {
                    Image(systemName: OnboardingSteps.symbol(index, current: current))
                        .foregroundStyle(index < current ? Color.green : index == current ? Color.accentColor : Color.secondary)
                        .font(.body.weight(index == current ? .semibold : .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityLabel(index < current ? Text("Done") : index == current ? Text("Current step") : Text("Not started"))
                    Text(item.title)
                        .fontWeight(index == current ? .semibold : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding-step-" + String(index))
            }
            Spacer()
        }
        .padding(.horizontal, Space.l)
        .animation(Motion.change(reduceMotion), value: step)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .check: checkStep
        case .start: EmptyView()
        }
    }

    // MARK: Step 1

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.m) {
                // One room: the character at work, a terminal on the laptop.
                StagedRoom(scene: .welcome, icon: .image(AgentScreen.image(RoomScene.welcome.color)),
                           side: RoomSize.welcome, entrance: true)
                Text(WelcomeCopy.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            featureRow("hand.raised") { Text(WelcomeCopy.approve) }
            featureRow("lock.shield") { Text(WelcomeCopy.room) }
            featureRow("arrow.triangle.branch") { Text(WelcomeCopy.copy) }
            Text(WelcomeCopy.apps)
                .font(.callout)
                .labelInk()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A row of step 1: a 24 pt accent symbol, then one sentence.
    private func featureRow<Content: View>(_ symbol: String, @ViewBuilder text: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            text()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Step 2

    private var paddockRow: PrereqRow {
        var verdict: VersionGate.Verdict?
        if case .found(_, let v) = store.binary { verdict = v }
        return WelcomeChecks.paddockRow(binary: verdict, missing: store.binary == .missing)
    }

    private var agentChecks: [AgentCheck] {
        WelcomeChecks.agents(agents.harnesses)
    }

    /// Step 2 as a checklist: paddock, the agents with their characters,
    /// and the free space.
    private var checkStep: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Check this Mac").font(.title2.bold())
            PrereqRowView(row: paddockRow, checking: checking) { Task { await check(again: true) } }
            Divider()
            agentsBlock
            if let free {
                Divider()
                PrereqRowView(row: WelcomeChecks.spaceRow(free: free), checking: checking) {}
            }
        }
        .animation(Motion.change(reduceMotion), value: paddockRow)
        .animation(Motion.change(reduceMotion), value: agentChecks)
    }

    /// The agents of `paddock list --json`: the ones that paddock found
    /// with their paths, then the ones that it knows and did not find,
    /// with the install line. Without a checked paddock the list is not
    /// known yet.
    private var agentsBlock: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Agents").font(.headline)
            if agents.usesFallbackPath {
                Text(WelcomeCopy.shellFallback)
                    .font(.callout)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("welcome-shell-fallback")
            }
            if !store.binary.isUsable {
                Text("The agents show here after paddock passes its check.")
                    .fixedSize(horizontal: false, vertical: true)
            } else if !agents.harnessesLoaded {
                ProgressView { Text("Looking for agents…") }
                    .controlSize(.small)
            } else if agents.gaps.contains(.list) {
                Text(AgentGap.list.line)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("welcome-agents-needs-list")
            } else if agentChecks.isEmpty {
                Text("paddock lists no agents.")
            } else {
                ForEach(agentChecks) { check in
                    AgentCheckRow(check: check)
                }
                if agentChecks.contains(where: { !$0.installed }) || agents.usesFallbackPath {
                    HStack(spacing: Space.s) {
                        Button("Look again") { Task { await checkAgents() } }
                            .disabled(checking)
                            .accessibilityIdentifier("agents-check-again")
                        Text(WelcomeCopy.lookAgain)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-agents")
    }

    // MARK: Step 3

    /// The New Agent form, inline. Start is in the footer of the window.
    private var startStep: some View {
        Form {
            Section {
                Text("Start your first agent").font(.title2.bold())
                Text("Choose an agent and a project folder. The agent opens in the paddock window.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            NewAgentFields(form: $form, loaded: formLoaded, welcome: true)
            if let error = agents.lastError {
                Section {
                    ProblemLine {
                        Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("new-agent-error")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay { DropHighlight(active: dropTargeted) }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = AgentForm.droppedFolder(urls.filter(\.isFileURL).map(\.path), isFolder: NewAgentSheet.isFolder)
            else { return false }
            form.choose(folder: folder, isGit: NewAgentSheet.isGit(folder))
            return true
        } isTargeted: { dropTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-start-form")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            switch step {
            case .welcome:
                Button("Quit") { NSApp.terminate(nil) }
            case .check:
                EmptyView()
            case .start:
                Button("Skip for now") { finish() }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("onboarding-skip")
            }
            Spacer()
            if step == .start, let missing = NewAgentFields.missing(form, loaded: formLoaded) {
                Text(missing)
                    .font(.callout)
                    .labelInk()
                    .lineLimit(1)
                    .accessibilityIdentifier("new-agent-missing")
            }
            if step != .welcome {
                Button("Back") { router.welcomeStep = step.rawValue - 1 }
            }
            switch step {
            case .welcome, .check:
                Button("Continue") { router.welcomeStep = step.rawValue + 1 }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .check && !WelcomeChecks.canContinue(paddockRow))
                    .accessibilityIdentifier("onboarding-continue")
            case .start:
                Button("Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!form.canStart)
                    .accessibilityIdentifier("onboarding-start")
            }
        }
    }

    // MARK: Actions

    /// Start: the run begins in a pane, and the main window opens on it.
    private func start() {
        guard NewAgentActions.start(form, agents: agents, store: store) != nil else { return }
        finish()
    }

    /// The end of the welcome, by Start or by "Skip for now": the main
    /// window, and no welcome at the next launch.
    private func finish() {
        LauncherDefaults.setWelcomeDone()
        store.welcomeDone = true
        openWindow(id: WindowID.main)
        dismissWindow(id: WindowID.onboarding)
        router.welcomeStep = WelcomeStep.welcome.rawValue
    }

    private func check(again: Bool = false) async {
        checking = true
        defer { checking = false }
        if again { await AppContainer.checkAgain() }
        free = LocalDisk.freeBytes()
        if store.binary.isUsable { await agents.loadChoices() }
    }

    /// Look again: the shell once more, for a PATH that an install
    /// changed, then `paddock list --json` once more.
    private func checkAgents() async {
        checking = true
        defer { checking = false }
        await AppContainer.lookAgain()
    }

    private func loadForm() async {
        var next = await NewAgentActions.load(agents: agents, store: store, folder: form.folder)
        // A newer load (a step change) owns the result.
        guard !Task.isCancelled else { return }
        if formLoaded {
            // A second load keeps what you chose in the first form.
            if let harness = form.harness { next.choose(harness: harness) }
            if form.modeChosen { next.choose(mode: form.mode) }
            next.network = form.network
            next.worktree = form.worktree && next.isGitProject
        }
        form = next
        formLoaded = true
    }
}

/// One agent of step 2: its character, its name, the path where paddock
/// found it, or the install command when it is not installed.
@MainActor
struct AgentCheckRow: View {
    let check: AgentCheck

    static let side: CGFloat = 56

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            RoomView(scene: RoomScene(tint: .cream, color: check.color, pose: check.installed ? .idle : .sleep),
                     icon: .image(AgentScreen.image(check.color)), side: AgentCheckRow.side)
                .frame(width: AgentCheckRow.side, height: AgentCheckRow.side)
                // Greyed out: the room, not the words, which must stay readable.
                .saturation(check.installed ? 1 : 0)
                .opacity(check.installed ? 1 : 0.5)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: check.title).font(.headline).labelInk()
                Text(check.result).labelInk().fixedSize(horizontal: false, vertical: true)
                if let path = check.shownPath(home: NSHomeDirectory()) {
                    Text(verbatim: path)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .labelInk()
                        .help(Text(verbatim: check.path ?? path))
                        .accessibilityIdentifier("welcome-agent-path")
                }
                if let command = check.install { CopyField(command: command) }
            }
            Spacer(minLength: Space.s)
            StatusSymbol(name: check.installed ? "checkmark.circle" : "arrow.down.circle",
                         tint: check.installed ? .green : .secondary, label: check.mark)
                .font(.title3)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome-agent-" + check.harness)
    }
}

/// The symbols of the welcome steps: a check when done, a filled ring
/// for the current step, an empty ring for the rest.
enum OnboardingSteps {
    static func symbol(_ index: Int, current: Int) -> String {
        if index < current { return "checkmark.circle.fill" }
        if index == current { return "circle.inset.filled" }
        return "circle"
    }
}

/// The step and whether paddock passed its checks: the work of a step
/// runs again when either changes.
private struct StepTrigger: Equatable {
    var step: WelcomeStep
    var usable: Bool
}

/// The free space that this Mac can give: the disk of the home folder.
enum LocalDisk {
    static func freeBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
