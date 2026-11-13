import AppKit
import PaddockKit
import SwiftUI

/// The base image (the golden in paddock's words): none, building, failed,
/// ready or needs-update.
///
/// With no base image this page is the guided step of the Apps section:
/// what the base image is, its size and time, the checks of this Mac for
/// Mac apps, and Build. Add App leads here while no base image is there.
/// An app that Add App kept (`store.pendingAdd`) has its room at the top
/// of the page, with the build under it; when the build ends the add
/// goes on by itself. With no app kept, the page offers Add App again.
@MainActor
struct BaseImageView: View {
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    /// The doctor of the guided step. `checking` only while a doctor runs:
    /// a failed or silent paddock ends as a failed row with Check again.
    @State private var doctor: DoctorPhase = .checking
    @State private var checking = false
    @State private var useIPSW = false
    @State private var ipsw: String?

    @State private var advancedOpen = false

    var body: some View {
        Form {
            if let pending = store.pendingAdd {
                PendingAppSection(pending: pending)
            }
            switch store.golden {
            case .none:
                guide
            case .building(let progress):
                BuildProgressSection(progress: progress, showsRoom: store.pendingAdd == nil)
            case .failed(let failure):
                BuildFailureSection(failure: failure, showsRoom: store.pendingAdd == nil)
            case .ready(let info):
                // With an app kept, the add runs by itself: no button.
                if router.addAfterBuild, router.pendingApp == nil { doneSection }
                readySection(info)
            case .needsUpdate(let info, _):
                readySection(info)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Base image"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Base image"))
        .accessibilityIdentifier("base-image")
        // Again when the binary check ends, and when a base image goes.
        .task(id: GuideTrigger(guided: store.golden == .none, usable: store.binary.isUsable)) {
            if store.golden == .none { await check() }
        }
    }

    // MARK: The guided step

    private var rows: [PrereqRow] {
        var verdict: VersionGate.Verdict?
        if case .found(_, let v) = store.binary { verdict = v }
        return Prerequisites.rows(phase: doctor, binary: verdict, binaryMissing: store.binary == .missing)
    }

    private var canBuild: Bool {
        store.binary.isUsable && Prerequisites.canContinue(rows)
    }

    /// No base image yet: what it is, what it costs, and Build. Then the
    /// checks of this Mac. The folder and the restore image are advanced.
    @ViewBuilder private var guide: some View {
        Section {
            BaseImageHero(pose: .sleep, showsRoom: store.pendingAdd == nil) {
                Text("Mac apps need a base image").font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("base-image-guide")
                Text("A Mac app runs in its own macOS virtual machine. paddock builds one base image of macOS, once. Each app starts from a copy of it. Your agents do not need it.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Build…") {
                    router.addAfterBuild = true
                    store.build(ipsw: useIPSW ? ipsw : nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canBuild)
                .padding(.top, Space.xs)
                .accessibilityIdentifier("build-button")
                if !store.binary.isUsable {
                    ProblemLine { Text(LibraryCopy.offline) }
                }
            }
            LabeledContent("Size") { Text("About 13 GB to download, about 25 GB on disk").labelInk() }
            LabeledContent("Time") { Text("10 to 30 minutes on a fast connection").labelInk() }
            LabeledContent("Pause") { Text("You can pause the download, quit, and continue later.").labelInk() }
        }
        Section {
            ForEach(rows) { row in
                PrereqRowView(row: row, checking: checking) { Task { await check(again: true) } }
            }
            if let disk = doctor.report?.disk {
                SpaceGauge(free: disk.free, need: disk.need)
            }
        } header: {
            Text("This Mac")
        }
        Section {
            AdvancedToggle(open: $advancedOpen, identifier: "base-image-advanced")
            if advancedOpen {
                LabeledContent("Keep in") {
                    Text(verbatim: Format.tildePath(LocalDoctor.defaultDir, home: NSHomeDirectory()))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .labelInk()
                }
                Toggle("Use a restore image I already have…", isOn: $useIPSW)
                    .onChange(of: useIPSW) { _, on in
                        if on, ipsw == nil { ipsw = Pickers.restoreImage() }
                        if ipsw == nil { useIPSW = false }
                    }
                if useIPSW, let ipsw {
                    Text(verbatim: ipsw).lineLimit(1).truncationMode(.middle).labelInk()
                }
                CommandEcho(args: LibraryArgs.setup(ipsw: useIPSW ? ipsw : nil, resume: false))
            }
        }
    }

    /// After the build of the guided step: the way back to Add App.
    private var doneSection: some View {
        Section {
            Label { Text("Base image ready").font(.title2.bold()) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("base-image-done")
            Text("Add an app from your Applications folder to start.")
            HStack {
                Button("Add App…") {
                    router.addAfterBuild = false
                    router.pendingApp = nil
                    router.sheet = .addApp(path: nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("base-image-add-app")
                Spacer()
            }
        }
    }

    private func check(again: Bool = false) async {
        checking = true
        defer { checking = false }
        doctor = .checking
        if again { await AppContainer.checkAgain() }
        let phase: DoctorPhase
        if store.binary.isUsable, let service = store.service {
            // Bounded by DoctorPhase.limits: past 20 s paddock is killed and
            // the row says that paddock did not answer.
            phase = await DoctorPhase.run(service)
        } else {
            phase = .report(LocalDoctor.make())
        }
        // A newer check (Check again, a new binary state) owns the result.
        if !Task.isCancelled { doctor = phase }
    }

    /// The base image is there: its room, what it is, and where. An update
    /// of macOS shows as the one action. Remove is advanced.
    @ViewBuilder
    private func readySection(_ info: GoldenInfo) -> some View {
        Section {
            BaseImageHero(pose: .idle, showsRoom: store.pendingAdd == nil) {
                Text("The base image is ready").font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(BuildCopy.readyLine(info)).labelInk()
                    .accessibilityIdentifier("golden-ready-line")
                // A count shows when there is something to count.
                if info.appsUsing > 0 {
                    Text(OverviewCopy.appsUsing(info.appsUsing)).labelInk()
                } else {
                    Text("No app uses it yet. Add an app to give it a room.").labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .needsUpdate(_, let host) = store.golden {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(BuildCopy.needsUpdate(host: host, image: info.version))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(UIText("macOS %@ can be built for the apps.", host)).font(.callout).labelInk()
                    }
                    Spacer()
                    Button("Update…") { router.sheet = .rebuild }
                        .disabled(store.isBuilding || store.buildRunning)
                        .accessibilityIdentifier("update-golden")
                }
            }
            if let note = store.buildNote {
                BuildNoteLine(note: note, details: store.buildNoteDetails)
            }
            if let dir = info.dir {
                LabeledContent("Location") {
                    HStack {
                        Text(verbatim: Format.tildePath(dir, home: NSHomeDirectory())).labelInk()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Reveal in Finder") { SystemLinks.reveal(dir) }
                    }
                }
            }
        }
        Section {
            AdvancedToggle(open: $advancedOpen, identifier: "base-image-advanced")
            if advancedOpen {
                let busy = store.apps.contains { $0.state.holdsSession }
                LabeledContent {
                    Button("Remove Base Image…", role: .destructive) { router.sheet = .removeGolden }
                        .disabled(busy)
                } label: {
                    Text("Remove the base image").labelInk()
                    if busy {
                        Text("Stop the running apps first.").labelInk()
                    } else {
                        Text("Apps cannot start until you build it again. App data stays.").labelInk()
                    }
                }
                LabeledContent {
                    SettingsLink { Text("Storage…") }
                } label: {
                    Text("See what paddock keeps on this disk").labelInk()
                }
            }
        }
    }
}

/// The hero of the Base image page: the room on the left, the title, the
/// state and the one action on the right. With an app that waits, its
/// own room is above already, so this one has no room.
@MainActor
struct BaseImageHero<Content: View>: View {
    let pose: CharacterPose
    let showsRoom: Bool
    let content: Content

    init(pose: CharacterPose, showsRoom: Bool, @ViewBuilder content: () -> Content) {
        self.pose = pose
        self.showsRoom = showsRoom
        self.content = content()
    }

    static var side: CGFloat { RoomSize.welcome }

    var body: some View {
        HStack(alignment: .center, spacing: Space.xl) {
            if showsRoom {
                StagedRoom(scene: RoomScene(tint: .mint, color: .gray, pose: pose),
                           icon: .image(NSApp.applicationIconImage), side: BaseImageHero.side)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                content
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s)
    }
}

/// "Advanced", closed until you open it: a plain button, so the rows
/// under it are real controls with their own identifiers.
@MainActor
struct AdvancedToggle: View {
    @Binding var open: Bool
    let identifier: String

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Advanced")
                Spacer(minLength: 0)
            }
            .labelInk()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? Text("Open") : Text("Closed"))
        .accessibilityIdentifier(identifier)
    }
}

/// Whether the guided step shows, and whether paddock passed its checks:
/// the doctor runs again when either changes.
private struct GuideTrigger: Equatable {
    var guided: Bool
    var usable: Bool
}

/// The free space on this disk against what the build needs, as a bar with
/// the two sizes. Orange when the space is short.
@MainActor
struct SpaceGauge: View {
    let free: Int64
    let need: Int64

    var body: some View {
        let text = UIText("Needs about %@, %@ free", Format.gb(need), Format.gb(free))
        VStack(alignment: .leading, spacing: Space.xs) {
            Gauge(value: Double(min(need, max(free, 1))), in: 0...Double(max(free, 1))) {
                Text("Space")
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(free >= need ? Color.blue : Color.orange)
            .labelsHidden()
            .accessibilityLabel(Text("Space"))
            .accessibilityValue(Text(text))
            Text(text)
                .font(.callout)
                .labelInk()
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-gauge")
    }
}

/// The checks the launcher can do without paddock, for the checklist when
/// paddock is missing: chip, macOS version, free space and memory. The
/// report has no `checks`, so the rows come from the numbers.
enum LocalDoctor {
    static let needBytes: Int64 = 40_000_000_000

    /// Where paddock keeps the base image unless it says another folder.
    static var defaultDir: String {
        NSHomeDirectory() + "/Library/Application Support/paddock/macvm"
    }

    static func make() -> DoctorJSON {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isApple = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DoctorJSON(chip: DoctorChipJSON(appleSilicon: isApple),
                          disk: DoctorDiskJSON(free: LocalDisk.freeBytes() ?? 0, need: needBytes),
                          macos: DoctorMacOSJSON(version: "\(os.majorVersion).\(os.minorVersion)", minMajor: 14,
                                                 ok: os.majorVersion >= 14),
                          memory: DoctorMemoryJSON(bytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory)))
    }
}

/// A build of the base image as one calm page: the room with the
/// character at work, what the build does now, ONE progress bar with the
/// time, and the four steps as a short checklist. Then Pause, Resume and
/// Cancel, and the note that the window can close.
@MainActor
struct BuildProgressSection: View {
    let progress: BuildProgress
    var showsRoom = true
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cancel: (() -> Void)?

    var body: some View {
        Section {
            BaseImageHero(pose: progress.paused ? .idle : .work, showsRoom: showsRoom) {
                Text(progress.headline).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("build-headline")
                ProgressView(value: progress.overallFraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(Motion.change(reduceMotion), value: progress.overallFraction)
                    .accessibilityLabel(Text("Building the base image"))
                    .accessibilityIdentifier("build-progress")
                // What the step does and the time, on one line.
                Text(verbatim: detail)
                    .font(.callout)
                    .labelInk()
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("step-detail-" + progress.step.rawValue)
                if showsEstimate {
                    Text(progress.estimate).font(.callout).labelInk()
                        .accessibilityIdentifier("build-estimate")
                }
                if progress.step == .guided {
                    Text("Follow the steps in paddock's setup window.")
                        .font(.callout.weight(.semibold))
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The steps as a checklist: one short line each.
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(BuildStep.allCases, id: \.self) { step in
                    stepRow(step)
                }
            }
            .padding(.vertical, Space.xs)
            // Pause and Resume stay in the tree for the whole build. Adding
            // or removing them while the accessibility audit runs makes the
            // parent lose a child.
            HStack {
                Button("Pause") { Task { await store.pauseBuild() } }
                    .disabled(!canPause)
                    .accessibilityIdentifier("pause-button")
                Button("Resume") { store.resumeBuild() }
                    .disabled(!canResume)
                    .accessibilityIdentifier("resume-button")
                Spacer()
                Button("Cancel") {
                    if let cancel { cancel() } else { router.sheet = .cancelBuild }
                }
                .accessibilityIdentifier("cancel-build")
            }
            if let note = store.buildNote {
                BuildNoteLine(note: note, details: store.buildNoteDetails)
            }
            Text(BuildCopy.closeNote)
                .font(.callout)
                .labelInk()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("close-note")
        }
    }

    private var canPause: Bool { progress.step == .download && !progress.paused }
    private var canResume: Bool { progress.step == .download && progress.paused }

    /// The line of the current step: `6.2 of 13.1 GB · 48 % · 9 min left`.
    private var detail: String {
        progress.detail(of: progress.step)?.localized ?? ""
    }

    /// The usual time of the whole build shows until the download has its
    /// own estimate. The line above has the time of the other steps.
    private var showsEstimate: Bool {
        progress.step == .download && !progress.paused && !progress.showsEstimate
    }

    /// One step of the checklist: its mark and its name. The mark says
    /// done, in progress, paused or not started.
    private func stepRow(_ step: BuildStep) -> some View {
        let status = progress.status(of: step)
        let current = status == .current || status == .paused
        return HStack(spacing: Space.s) {
            StatusSymbol(name: status.symbol, tint: status.tint, label: status.accessibilityLabel)
                .frame(width: 18)
            Text(step.title)
                .fontWeight(current ? .semibold : .regular)
                .labelInk()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("step-" + step.rawValue)
    }
}

/// paddock's answer to Pause, Resume or Update, under the steps: a plain
/// sentence, and paddock's own line under Details when it has one.
@MainActor
struct BuildNoteLine: View {
    let note: UIText
    let details: String?

    var body: some View {
        ProblemLine {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(note).labelInk()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build-note")
                if let details { DetailsDisclosure(text: details) }
            }
        }
    }
}

/// The room of the app that waits for the base image, at the top of the
/// Base image page: the app on its laptop, its name, and what happens
/// next. The build shows right under it. A failed add shows here, with
/// Try Again.
@MainActor
struct PendingAppSection: View {
    let pending: PendingAdd
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: Space.l) {
                StagedRoom(scene: RoomScene(tint: .cream, color: CharacterColor.of(app: pending.title),
                                            pose: pending.pose(golden: store.golden),
                                            showsProgress: pending.phase == .adding),
                           icon: .app(path: pending.path), side: PendingAppSection.roomSide)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(verbatim: pending.title).font(.title2.bold()).labelInk()
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("pending-app-title")
                    Text(pending.next(golden: store.golden))
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pending-app-next")
                }
                Spacer(minLength: 0)
            }
            if let problem = pending.problem {
                InlineProblemView(problem, id: "pending-app-problem")
            }
            HStack {
                if pending.problem != nil {
                    Button("Try Again") { store.retryPendingAdd() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pending-app-retry")
                    // The review sheet names every check of paddock.
                    Button("Review…") {
                        store.dropPendingAdd()
                        router.pendingApp = nil
                        router.addAfterBuild = false
                        router.sheet = .addApp(path: pending.path)
                    }
                    .accessibilityIdentifier("pending-app-review")
                }
                Spacer()
                Button("Do Not Add") {
                    store.dropPendingAdd()
                    router.pendingApp = nil
                }
                .disabled(pending.phase == .adding)
                .accessibilityIdentifier("pending-app-cancel")
            }
        }
    }

    static let roomSide: CGFloat = 96
}

/// The base image, on the page of an app that cannot start without it:
/// the build with its progress, or the failed build with its reason. The
/// hero of the app has the action that leads to the Base image page.
@MainActor
struct BaseImageWait: View {
    @Environment(LauncherStore.self) private var store

    /// True while a build runs or after it failed: there is something to
    /// show. A base image that was never begun has the note of the hero.
    static func shows(_ golden: GoldenState) -> Bool {
        switch golden {
        case .building, .failed: return true
        default: return false
        }
    }

    var body: some View {
        switch store.golden {
        case .building(let progress):
            VStack(alignment: .leading, spacing: Space.s) {
                Text(progress.headline).font(.headline)
                ProgressView(value: progress.overallFraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(progress.headline))
                Text(progress.detail(of: progress.step) ?? progress.estimate)
                    .font(.callout).labelInk().monospacedDigit()
                    .accessibilityIdentifier("app-build-detail")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .quietPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("app-build-progress")
        case .failed(let failure):
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Base image not built").font(.headline)
                    DetailedText(failure.problem.message)
                    if let details = failure.problem.details { DetailsDisclosure(text: details) }
                }
                Spacer(minLength: 0)
            }
            .quietPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("app-build-failed")
        default:
            EmptyView()
        }
    }
}

/// `Base image not built`: the room, the reason in a plain sentence, and
/// the next step as the one prominent button. The reason of paddock's
/// setup report shows in the language of the interface; the last line of
/// a build that ended by itself is under Details.
@MainActor
struct BuildFailureSection: View {
    let failure: BuildFailure
    var showsRoom = true
    @Environment(LauncherStore.self) private var store

    var body: some View {
        Section {
            BaseImageHero(pose: .blocked, showsRoom: showsRoom) {
                Label { Text("Base image not built").font(.title2.bold()) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                }
                DetailedText(failure.problem.message, id: "failure-reason")
                if let details = failure.problem.details { DetailsDisclosure(text: details) }
                if let hint = failure.hint { Text(hint).labelInk() }
                HStack {
                    Button { primary() } label: { Text(failure.primary.buttonTitle) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("failure-primary")
                    if failure.primary != .tryAgain {
                        Button("Try Again") { store.resumeBuild() }
                            .controlSize(.large)
                            .accessibilityIdentifier("failure-try-again")
                    }
                    Button("Show Log") {
                        SystemLinks.reveal(store.goldenLogPath ?? store.golden.info?.dir ?? store.logDir
                            ?? NSHomeDirectory() + "/Library/Application Support/paddock/macvm")
                    }
                    .controlSize(.large)
                }
                .padding(.top, Space.xs)
            }
        }
    }

    private func primary() {
        switch failure.primary {
        case .manageStorage: SystemLinks.manageStorage()
        case .tryAgain: store.resumeBuild()
        case .chooseRestoreImage:
            if let ipsw = Pickers.restoreImage() { store.build(ipsw: ipsw) }
        }
    }
}
