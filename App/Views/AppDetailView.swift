import PaddockKit
import SwiftUI

/// The detail of one app: a header, in-place errors, and the tabs
/// Overview, Grants and Log.
@MainActor
struct AppDetailView: View {
    let name: String
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        @Bindable var store = store
        let model = store.detail(for: name)
        VStack(spacing: 0) {
            if let app = store.app(named: name) {
                SessionHeader(app: app)
                    .padding(.horizontal, Space.page)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.l)
                notices(app)
            }
            // The tabs: a segmented control under the hero, as Raycast
            // and System Settings put them. Only the chosen tab is built.
            Picker("Show", selection: $store.detailTab) {
                Text("Overview").tag(DetailTab.overview)
                Text("Grants").tag(DetailTab.grants)
                Text("Log").tag(DetailTab.log)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, Space.xs)
            .accessibilityIdentifier("detail-tabs")
            Group {
                switch store.detailTab {
                case .overview: OverviewTab(model: model)
                case .grants: GrantsView(model: model)
                case .log: LogView(model: model).padding([.horizontal, .bottom], Space.page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: name) { await model.load(force: true) }
        .onChange(of: store.openRoom, initial: true) { _, room in
            // This detail is the room that was asked for.
            if room == .app(name) { store.openRoom = nil }
        }
    }

    @ViewBuilder
    private func notices(_ app: AppItem) -> some View {
        VStack(spacing: 0) {
            if let error = store.appErrors[name] {
                ErrorShape(error: error,
                           primary: { primary(for: error) },
                           showLog: { store.detailTab = .log },
                           stopChoices: stopChoices(error),
                           stop: { other in Task { await store.stopApp(other) } })
                    .padding(.bottom, Space.m)
            }
            if app.json.agentConnected == false, app.state.isRunning {
                ErrorShape(error: .agentAway)
                    .padding(.bottom, Space.m)
            }
            if app.json.appChanged == true {
                ErrorShape(error: .appChanged(app: app.title))
                    .padding(.bottom, Space.m)
            }
            if let line = app.json.copyFailed {
                ErrorShape(error: .appCopyFailed(app: app.title, line: line), primary: { store.detailTab = .log })
                    .padding(.bottom, Space.m)
            }
            if let hero = HeroAction.of(app.state, golden: store.golden, goldenLoaded: store.goldenLoaded),
               hero == .showBuild || hero == .buildBaseImage, BaseImageWait.shows(store.golden) {
                // The app waits for the base image: its page shows the
                // build or the failed build. The hero has the action.
                BaseImageWait()
                    .padding(.bottom, Space.m)
            }
        }
        .padding(.horizontal, Space.page)
    }

    private func stopChoices(_ error: LauncherError) -> [String] {
        if case .twoRunning(_, let running) = error { return running }
        return []
    }

    private func primary(for error: LauncherError) {
        switch error.primary {
        case .manageStorage: SystemLinks.manageStorage()
        case .startAgain: Task { await store.startApp(name) }
        case .showLog: store.detailTab = .log
        case .build: store.selection = .baseImage
        default: break
        }
    }
}

/// The Overview of an app, under its hero: the facts in groups, then the
/// advanced options behind a disclosure.
///
/// The hero says the state and has the main action, so no row repeats
/// them. A group never shows an empty meter or a zero: before the first
/// start the Storage group says what will happen.
@MainActor
struct OverviewTab: View {
    let model: AppDetailModel
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @State private var advancedOpen = false

    var body: some View {
        if let app = store.app(named: model.name) {
            Form {
                InstancesSection(app: app)
                facts(app)
                storage(app)
                network(app)
                advanced(app)
            }
            .formStyle(.grouped)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Overview"))
        }
    }

    // MARK: This app

    /// The facts that paddock gave. The group is not there when it has
    /// none: a new app shows its storage line and its network.
    @ViewBuilder
    private func facts(_ app: AppItem) -> some View {
        let next = NextStartCopy.line(app.json)
        let memory = OverviewCopy.memory(app.json)
        let fraction = OverviewCopy.memoryFraction(app.json)
        if next != nil || app.json.since != nil || (memory != nil && fraction != nil) || app.json.golden != nil {
            Section {
                if let next {
                    LabeledContent {
                        DetailedText(next, id: "overview-next-start").labelInk()
                    } label: { Text("Next start").labelInk() }
                }
                if let since = app.json.since {
                    LabeledContent {
                        Text(since, format: .dateTime.day().month().hour().minute()).labelInk()
                    } label: { Text("Running since").labelInk() }
                }
                if let memory, let fraction {
                    MemoryRow(text: memory, fraction: fraction)
                }
                if let golden = app.json.golden {
                    LabeledContent {
                        DetailedText(UIText.cli(golden, else: UIText("Ready"))).labelInk()
                    } label: { Text("Base image").labelInk() }
                }
            } header: {
                Text("This app")
            }
        }
    }

    // MARK: Storage

    @ViewBuilder
    private func storage(_ app: AppItem) -> some View {
        Section {
            switch StorageSummary.of(app.json) {
            case .nothingYet:
                Text(StorageSummary.nothingYetLine)
                    .labelInk()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("storage-empty")
            case .parts(let sizes):
                DiskBar(sizes: sizes)
            case .total(let bytes):
                LabeledContent { Text(verbatim: Format.gb(bytes)).labelInk().monospacedDigit() } label: {
                    Text("On disk").labelInk()
                }
            }
        } header: {
            Text("Storage")
        }
    }

    // MARK: Network

    @ViewBuilder
    private func network(_ app: AppItem) -> some View {
        let questions = store.questions.filter { $0.app == app.name }.count
        let rules = model.rules.isEmpty ? (app.json.ruleCount ?? 0) : model.rules.count
        Section {
            Picker("Access", selection: Binding(
                get: { model.networkMode },
                set: { mode in Task { await model.setNetwork(mode) } })) {
                ForEach(NetworkMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .menuAuditAction()
            .accessibilityIdentifier("overview-network")
            // A count shows when there is something to count.
            if questions > 0 {
                Button { store.selection = .questions } label: {
                    Text(OverviewCopy.openQuestions(questions))
                }
                .buttonStyle(.link)
            }
            if rules > 0 {
                Button { store.detailTab = .grants } label: {
                    Text(OverviewCopy.rules(rules))
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Network")
        }
    }

    // MARK: Advanced

    /// The options that you seldom need, closed until you open them:
    /// Clear saved state and Remove App. A plain button opens them, so
    /// the rows are real buttons with their own identifiers.
    @ViewBuilder
    private func advanced(_ app: AppItem) -> some View {
        Section {
            Button {
                advancedOpen.toggle()
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: advancedOpen ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("Advanced")
                    Spacer(minLength: 0)
                }
                .labelInk()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(advancedOpen ? Text("Open") : Text("Closed"))
            .accessibilityIdentifier("advanced-toggle")
            if advancedOpen {
                if StorageSummary.canClearSavedState(app.json, state: app.state) {
                    LabeledContent {
                        Button("Clear Saved State…") { router.sheet = .clearState(app.key) }
                            .accessibilityIdentifier("clear-state-button")
                    } label: {
                        Text("Saved state").labelInk()
                        Text("The next start is cold, about 30 s. Your data in the app stays.").labelInk()
                    }
                }
                LabeledContent {
                    Button("Remove App…", role: .destructive) { router.sheet = .removeApp(app.key) }
                        .accessibilityIdentifier("remove-app-button")
                } label: {
                    Text("Remove this app from paddock").labelInk()
                    Text("The original app in your Applications folder stays.").labelInk()
                }
            }
        }
    }
}

/// `paddock app log NAME --events`, as paddock prints it.
@MainActor
struct LogView: View {
    let model: AppDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Toggle("Follow", isOn: Binding(get: { model.following }, set: { model.setFollow($0) }))
                Spacer()
                Button("Copy") { Pasteboard.copy(model.logLines.joined(separator: "\n")) }
                Button("Reveal in Finder") {
                    if let path = model.status?.logPath { SystemLinks.reveal(path) }
                }
                .disabled(model.status?.logPath == nil)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(verbatim: model.logLines.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .labelInk()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s)
                    Color.clear.frame(height: 1).id("end")
                }
                .accessibilityLabel(Text("Log"))
                .accessibilityIdentifier("log-text")
                .onChange(of: model.logLines.count) { _, _ in
                    if model.following { proxy.scrollTo("end") }
                }
            }
            .background(.background)
            .border(.separator)
        }
        .padding(.top, Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Log"))
        .task { await model.loadLog() }
        .onDisappear { model.setFollow(false) }
    }
}

/// `Memory  6 of 16 GB` with a capacity gauge, as System Settings shows
/// memory. The value changes with the events stream.
@MainActor
struct MemoryRow: View {
    let text: UIText
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LabeledContent {
            HStack(spacing: Space.m) {
                Gauge(value: fraction) { Text("Memory") }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .labelsHidden()
                    .frame(width: 140)
                    .accessibilityLabel(Text("Memory"))
                    .accessibilityValue(Text(text))
                    .accessibilityIdentifier("memory-gauge")
                Text(text)
                    .labelInk()
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityHidden(true)
            }
            .animation(Motion.change(reduceMotion), value: fraction)
        } label: { Text("Memory").labelInk() }
    }
}

/// The disk of one app as one stacked bar, as macOS Storage draws it: app
/// copy blue, data teal, saved state gray. A legend with the sizes and the
/// total under it. Each color has its word in the legend.
@MainActor
struct DiskBar: View {
    let sizes: AppSizesJSON
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func color(_ kind: DiskPart.Kind) -> Color {
        switch kind {
        case .appCopy: return .blue
        case .data: return .teal
        case .savedState: return .gray
        }
    }

    var body: some View {
        let parts = OverviewCopy.diskParts(sizes)
        VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(parts) { part in
                        Rectangle()
                            .fill(DiskBar.color(part.kind))
                            .frame(width: max(0, proxy.size.width * part.fraction - 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 10)
            .background(.fill.tertiary)
            .clipShape(Capsule())
            .animation(Motion.change(reduceMotion), value: parts)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Disk"))
            .accessibilityValue(Text(verbatim: parts.map { $0.title.localized + " " + Format.gb($0.bytes) }
                .joined(separator: ", ")))
            .accessibilityIdentifier("disk-bar")
            HStack(spacing: Space.l) {
                ForEach(parts) { part in
                    HStack(spacing: 5) {
                        Circle().fill(DiskBar.color(part.kind)).frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(part.title).labelInk()
                        Text(verbatim: Format.gb(part.bytes))
                            .labelInk()
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("disk-legend-" + part.id)
                }
                Spacer(minLength: Space.s)
                HStack(spacing: 5) {
                    Text("Total").labelInk()
                    Text(verbatim: Format.gb(sizes.total))
                        .labelInk()
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.callout.weight(.semibold))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("disk-total")
            }
        }
        .padding(.vertical, Space.xs)
    }
}
