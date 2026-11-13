import AppKit
import PaddockKit
import SwiftUI

/// The open firewall questions. paddock's own panel next to the app's
/// window stays the place to answer; this list mirrors it. The launcher
/// never draws a second panel.
@MainActor
struct QuestionsView: View {
    @Environment(LauncherStore.self) private var store
    @Environment(AgentStore.self) private var agents
    @Environment(UIRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True while Clear Expired sends its answers.
    @State private var clearing = false
    /// paddock's line when an answer of Clear Expired did not arrive.
    @State private var clearFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            // The requests that nobody answered for a day, or that timed
            // out: one line says how many, and one button clears them.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ExpiredBanner(questions: store.questions.filter { RequestAge.isExpired($0, now: context.date) },
                              requests: store.agentRequests.filter { RequestAge.isExpired($0, now: context.date) },
                              clearing: clearing, failure: clearFailure, clear: clearExpired)
            }
            if let issue = store.questionsIssue {
                // A problem line, as in the sheets. The launcher's own
                // lines show as they are; a line of paddock goes under
                // Details, below a plain sentence.
                InlineProblemView(QuestionProblem.issue(issue), id: "questions-incomplete")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.page)
                    .padding(.top, Space.l)
            }
            if let paused = store.paused {
                GroupBox {
                    HStack(alignment: .top) {
                        Image(systemName: "pause.circle.fill").accessibilityHidden(true)
                        Text(QuestionsCopy.pausedBanner(paused))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("paused-banner")
                        Spacer()
                        Button("Deny all") { Task { await store.pausedDenyAll() } }
                            .accessibilityIdentifier("deny-all")
                        Button("Ask one by one") { Task { await store.pausedOneByOne() } }
                            .accessibilityIdentifier("ask-one-by-one")
                    }
                    .padding(Space.xs)
                }
                .backgroundStyle(.yellow.opacity(0.25))
                .padding(.horizontal, Space.page)
                .padding(.vertical, Space.l)
                .disabled(!store.pausedConfirmed)
            }
            if store.questions.isEmpty && store.agentRequests.isEmpty {
                let title: LocalizedStringKey = store.questionsComplete ? "No open questions" : "Questions are not confirmed" // localized
                PlainEmpty {
                    // Nothing waits: the character rests in its room.
                    VStack(spacing: Space.l) {
                        StagedRoom(scene: RoomScene(tint: .lilac, color: .gray, pose: .sleep),
                                   icon: .image(NSApp.applicationIconImage), side: RoomSize.welcome)
                        Text(title).font(.title2.bold())
                    }
                } description: {
                    Text("When an app wants to reach a new server, the question appears here and next to the app's window.")
                } actions: {
                    EmptyView()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(title))
                .accessibilityIdentifier("questions-empty")
            } else {
                let ordered = QuestionChoices.newestFirst(store.questions)
                let requests = AgentRequestOrder.newestFirst(store.agentRequests)
                let cards = requests.map(\.id) + ordered.map(\.id)
                // An expired card has no answers: the keys skip it.
                let keyed = requests.first { !RequestAge.isExpired($0, now: Date()) }?.id
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Space.m) {
                            // The requests of the agents, then the app
                            // questions. The keys go to the newest app
                            // question, else to the newest live request.
                            ForEach(requests) { request in
                                FocusedCard(focused: router.focusCard == request.id, id: request.id) {
                                    AgentRequestCard(request: request,
                                                     keys: ordered.isEmpty && request.id == keyed)
                                }
                                .id(request.id)
                                .transition(.opacity)
                            }
                            ForEach(ordered) { question in
                                FocusedCard(focused: router.focusCard == question.id, id: question.id) {
                                    QuestionCard(question: question, keys: question.id == ordered.first?.id)
                                }
                                .id(question.id)
                                .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, Space.page)
                        .padding(.vertical, Space.l)
                        .animation(Motion.change(reduceMotion), value: cards)
                    }
                    // A click on a notification: its card comes into view.
                    .onChange(of: router.focusCard, initial: true) { _, card in
                        guard let card else { return }
                        withAnimation(Motion.change(reduceMotion)) { proxy.scrollTo(card, anchor: .top) }
                    }
                    .onChange(of: cards) { _, ids in
                        // The card got its answer: nothing to point at.
                        if let card = router.focusCard, !ids.contains(card) { router.focusCard = nil }
                    }
                }
                .accessibilityLabel(Text("Questions"))
                .accessibilityIdentifier("questions-list")
            }
        }
        .navigationTitle(Text("Questions"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Questions"))
    }

    /// Clear Expired: No to each expired request of an agent, Deny to
    /// each expired question of an app. A card whose answer did not reach
    /// paddock stays, and the banner says so.
    private func clearExpired(_ questions: [QuestionJSON], _ requests: [AgentRequestJSON]) {
        clearing = true
        clearFailure = nil
        Task {
            var failure: String?
            for request in requests {
                if let line = await agents.answer(request, .deny) { failure = failure ?? line }
            }
            for question in questions {
                if let line = await store.answer(question, panel: .deny) { failure = failure ?? line }
            }
            clearFailure = failure
            clearing = false
        }
    }
}

/// `2 requests are older than a day or timed out.` with Clear Expired.
/// The line is not there when nothing expired.
@MainActor
struct ExpiredBanner: View {
    let questions: [QuestionJSON]
    let requests: [AgentRequestJSON]
    let clearing: Bool
    let failure: String?
    let clear: ([QuestionJSON], [AgentRequestJSON]) -> Void

    var body: some View {
        let count = questions.count + requests.count
        if count > 0 {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(RequestAge.expiredLine(count)).font(.headline).labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("expired-line")
                    Text(RequestAge.clearNote).font(.callout).labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                    if let failure {
                        InlineProblemView(QuestionProblem.of(failure), id: "expired-failed")
                            .font(.callout)
                    }
                }
                Spacer(minLength: Space.s)
                Button("Clear Expired") { clear(questions, requests) }
                    .disabled(clearing)
                    .accessibilityIdentifier("clear-expired")
            }
            .quietPanel()
            .padding(.horizontal, Space.page)
            .padding(.top, Space.l)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("expired-banner")
        }
    }
}

/// One open question as a card, in the order of Little Snitch: the app
/// icon and `ChatGPT wants to connect to`, the host large, the port and the
/// process small. Then the answers of paddock's panel in the panel's order,
/// all the same weight: `Deny`, `Allow once`, `Allow <site>`, and under
/// `More…` the session, permanent and ten-minute answers.
///
/// The newest card has the keys of the panel (D14): Esc denies, Return
/// allows once. No key writes a permanent rule.
@MainActor
struct QuestionCard: View {
    let question: QuestionJSON
    /// True for the newest card: it takes Esc and Return.
    var keys = false
    @Environment(LauncherStore.self) private var store
    @State private var failure: String?
    @State private var working = false

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: Space.m) {
                AppIcon(path: store.app(named: question.app)?.json.bundlePath, size: IconSize.question)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(QuestionChoices.lead(question))
                        .labelInk()
                        .accessibilityIdentifier("question-title-" + question.id)
                    Text(verbatim: question.host)
                        .font(.title3.monospaced())
                        .labelInk()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("question-host-" + question.id)
                    // `port 443 · example.com and all its subdomains`.
                    Text(QuestionChoices.detail(question)).font(.caption).labelInk()
                    if let caption = processLine {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(verbatim: caption(context.date))
                                .font(.caption)
                                .labelInk()
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if let failure {
                        // A plain sentence, with paddock's line under
                        // Details. The card stays for another answer.
                        InlineProblemView(QuestionProblem.of(failure), id: "answer-failed-" + question.id)
                            .font(.caption)
                    }
                    HStack(spacing: Space.s) {
                        ForEach(QuestionChoices.row(question)) { choice in
                            button(choice)
                                .buttonStyle(.bordered)
                                .keyboardShortcut(shortcut(for: choice.answer))
                        }
                        Spacer(minLength: Space.s)
                        Menu {
                            ForEach(QuestionChoices.menu(question)) { choice in
                                if choice.answer == .allowEverything { Divider() }
                                button(choice)
                            }
                        } label: {
                            Text("More…")
                        }
                        .fixedSize()
                        .menuAuditAction()
                        .accessibilityIdentifier("answer-more-" + question.id)
                    }
                    .padding(.top, Space.s)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s)
        }
        .disabled(working || !store.confirmedQuestionIDs.contains(question.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(QuestionChoices.title(question)))
        .accessibilityIdentifier("question-" + question.id)
    }

    /// `Sample Notes.app → helper (Renderer) · 3 min ago`, from the parts
    /// paddock sent.
    private var processLine: ((Date) -> String)? {
        guard question.process != nil || question.opened != nil else { return nil }
        let process = question.process
        let opened = question.opened
        return { now in
            var parts: [String] = []
            if let process { parts.append(process) }
            if let opened { parts.append(Format.age(since: opened, now: now).localized) }
            return parts.joined(separator: " · ")
        }
    }

    private func shortcut(for answer: PanelAnswer) -> KeyboardShortcut? {
        guard keys else { return nil }
        switch answer {
        case .deny: return .cancelAction
        case .allowOnce: return .defaultAction
        default: return nil
        }
    }

    private func button(_ choice: QuestionChoice) -> some View {
        Button { answer(choice.answer) } label: { Text(choice.title) }
            .accessibilityLabel(Text(choice.label))
            .accessibilityIdentifier("answer-" + choice.answer.rawValue + "-" + question.id)
    }

    private func answer(_ answer: PanelAnswer) {
        working = true
        Task {
            failure = await store.answer(question, panel: answer)
            working = false
        }
    }
}

/// A card of the Questions list that a notification points to: one line
/// above it and an accent edge, so you find the request you clicked.
@MainActor
struct FocusedCard<Content: View>: View {
    let focused: Bool
    let id: String
    let content: Content

    init(focused: Bool, id: String, @ViewBuilder content: () -> Content) {
        self.focused = focused
        self.id = id
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if focused {
                Label { Text("From your notification").font(.caption).labelInk() } icon: {
                    DecorativeSymbol(name: "bell.fill")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("card-focus-" + id)
            }
            content
                .overlay {
                    if focused {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .accessibilityHidden(true)
                    }
                }
        }
    }
}

/// The problem of an answer that did not reach paddock.
enum QuestionProblem {
    /// The lines that the launcher writes itself about the question list.
    /// Each is a text of the catalog, so it shows in the language of the
    /// interface.
    static let ownTexts: [UIText] = [
        UIText("Could not load questions."),
        UIText("The question list is incomplete."),
        UIText("Live updates paused; questions are not confirmed."),
        UIText("Some live updates were missed; checking questions."),
    ]

    static let own = Set(ownTexts.map(\.key))

    /// The line above the Questions list.
    static func issue(_ line: String) -> InlineProblem {
        if let mine = ownTexts.first(where: { $0.key == line }) { return InlineProblem(message: mine) }
        let problem = PlainError.problem(line)
        if problem.details == nil { return problem }
        return InlineProblem(message: UIText("The questions could not be read completely. Refresh to check them."),
                             details: line)
    }

    static func of(_ line: String) -> InlineProblem {
        let problem = PlainError.problem(line)
        // A sentence of the launcher stands as it is.
        if problem.details == nil { return problem }
        return InlineProblem(message: UIText("The answer did not reach paddock. Answer again."), details: problem.details)
    }
}
