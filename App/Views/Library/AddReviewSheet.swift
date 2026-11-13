import AppKit
import PaddockKit
import SwiftUI

/// Add App: the app, paddock's dry run as a checklist, then `Add`. The
/// same sheet for `+`, Command-N, a drop on the window and a drop on the
/// Dock icon. Queued drops come one after another.
///
/// When paddock refuses the app only because the base image is missing,
/// the sheet does not stop at that line: the app waits, and the window
/// goes straight on to the base image step (`UIRouter.waitForBaseImage`).
/// A failed check or add shows here, as a plain sentence with paddock's
/// line under Details.
@MainActor
struct AddReviewSheet: View {
    let initialPath: String?
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var review: AddReview?
    @State private var name = ""
    @State private var memory = 6
    @State private var adding = false
    @State private var refusal: String?
    private var center: AddCenter { AddCenter.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if let position = center.queue.position, initialPath != nil {
                    Text(position).font(.callout).accessibilityIdentifier("add-position")
                }
                if let path {
                    header(path)
                    if let review {
                        checklist(review)
                        if review.canAdd { choices(review) }
                    } else {
                        Section {
                            ProgressView { Text("Checking the app…") }
                                .accessibilityIdentifier("add-checking")
                        }
                    }
                } else {
                    Section { ProgressView { Text("Choose an app…") } }
                }
                if let refusal {
                    Section {
                        InlineProblemView(line: refusal, id: "add-refusal")
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            buttons.padding(Space.l)
        }
        .frame(width: 500)
        .frame(minHeight: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Add App…"))
        .task { await start() }
        .onDisappear { center.finished(initialPath) }
    }

    // MARK: Parts

    private func header(_ path: String) -> some View {
        Section {
            HStack(spacing: Space.m) {
                AppIcon(path: path, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: review?.displayName ?? AddReview.slugBase(path)).font(.headline)
                    Text(verbatim: Format.tildePath(path, home: NSHomeDirectory()))
                        .font(.callout)
                        .labelInk()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let bytes = review?.bytes {
                        Text(verbatim: Format.gb(bytes)).font(.callout).labelInk()
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func checklist(_ review: AddReview) -> some View {
        Section {
            if let failure = review.failure {
                InlineProblemView(line: failure, id: "add-message")
            }
            if let existing = review.existing {
                HStack {
                    Text(LibraryCopy.existing(existing)).accessibilityIdentifier("add-message")
                    Spacer()
                    Button("Show App") {
                        store.selection = .app(existing)
                        dismiss()
                    }
                }
            }
            ForEach(review.checks) { check in
                CheckRow(check: check, isFirstFailure: check.id == review.firstFailure?.id, path: review.path,
                         dismiss: { dismiss() })
            }
            if review.canCheckAgain {
                Button("Check Again") { Task { await recheck() } }
                    .accessibilityIdentifier("add-check-again")
            }
        } header: {
            Text("Before it is added")
        }
    }

    private func choices(_ review: AddReview) -> some View {
        Section {
            TextField("Name", text: $name)
                .accessibilityIdentifier("add-name")
            Picker("Memory", selection: $memory) {
                ForEach(review.memoryOptions, id: \.self) { gb in
                    Text(verbatim: Format.memoryGB(Int64(gb) * 1_073_741_824)).tag(gb)
                }
            }
            .menuAuditAction()
            CommandEcho(args: LibraryArgs.add(review.path, name: name, memoryGB: memory))
        } footer: {
            Text("The app gets a launcher in your Applications folder, so it also starts from the Dock and Launchpad.")
        }
    }

    private var buttons: some View {
        HStack {
            if center.queue.total > 1, initialPath != nil {
                Button("Cancel All") {
                    center.cancelAll()
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(review?.canAdd != true || trimmedName.isEmpty || adding)
                .accessibilityIdentifier("add-confirm")
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    // MARK: Actions

    private func start() async {
        guard path == nil else { return }
        guard let picked = initialPath ?? Pickers.app() else { return dismiss() }
        path = picked
        let result = await store.review(path: picked)
        if goOnToBaseImage(result) { return }
        review = result
        name = result.name
        memory = result.defaultMemory
    }

    /// True when the sheet handed the app to the base image step: paddock
    /// refuses it only because the base image is missing, and the launcher
    /// knows of no base image either. The app waits there, and the add
    /// goes on by itself after the build.
    private func goOnToBaseImage(_ result: AddReview) -> Bool {
        guard AddHandoff.needsBaseImage(result, golden: store.golden) else { return false }
        center.cancelAll()
        router.waitForBaseImage(path: result.path, store: store)
        dismiss()
        return true
    }

    /// Check Again: the dry run once more, for example after a build or
    /// after space was freed. The sheet shows "Checking the app…" meanwhile.
    private func recheck() async {
        guard let path else { return }
        review = nil
        refusal = nil
        let result = await store.review(path: path)
        if goOnToBaseImage(result) { return }
        review = result
        if name.isEmpty { name = result.name }
        if !result.memoryOptions.contains(memory) { memory = result.defaultMemory }
    }

    private func add() {
        guard let review else { return }
        adding = true
        refusal = nil
        Task {
            let outcome = await store.add(path: review.path, name: trimmedName, memoryGB: memory)
            adding = false
            switch outcome {
            case .added: dismiss()
            case .refused(let line): refusal = line
            }
        }
    }
}

/// One row of the review checklist: symbol, title, text, and the action
/// of a failed row.
@MainActor
struct CheckRow: View {
    let check: AddCheck
    let isFirstFailure: Bool
    /// The app of the review: Build… keeps it for after the build.
    let path: String
    let dismiss: () -> Void
    @Environment(LauncherStore.self) private var store
    @Environment(UIRouter.self) private var router

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            StatusSymbol(name: check.symbol, tint: check.tint, label: check.accessibilityLabel)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(check.title).font(.headline)
                Text(check.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(isFirstFailure ? "add-message" : "check-detail-" + check.id)
                if let action = check.action { actionButton(action) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(check.title))
        .accessibilityIdentifier("check-" + check.id)
    }

    @ViewBuilder
    private func actionButton(_ action: AddCheck.Action) -> some View {
        switch action {
        case .openWebsite(let site):
            if let url = URL(string: site) {
                Button("Open website") { SystemLinks.open(url) }
            }
        case .build:
            Button("Build…") {
                // The app waits for the base image; the add goes on by
                // itself when it is ready.
                AddCenter.shared.cancelAll()
                router.waitForBaseImage(path: path, store: store)
                Task { await store.reloadStatusNow() }
                dismiss()
            }
            .accessibilityIdentifier("add-build")
        case .manageStorage:
            Button("Manage Storage…") { SystemLinks.manageStorage() }
        }
    }
}

/// When the review sheet hands an app to the base image step.
enum AddHandoff {
    /// paddock refuses the app for the base image and for nothing else,
    /// and the launcher has no ready base image. With a ready base image
    /// in the launcher the row stays, with its Build… button: the two do
    /// not agree, and you decide.
    static func needsBaseImage(_ review: AddReview, golden: GoldenState) -> Bool {
        guard !golden.isReady, review.existing == nil, review.failure == nil else { return false }
        let failed = review.checks.filter { $0.status == .fail }
        return !failed.isEmpty && failed.allSatisfy { $0.kind == .golden }
    }
}
