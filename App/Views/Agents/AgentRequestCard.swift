import PaddockKit
import SwiftUI

/// A request of an agent, as the card of the video: the pill "Approval
/// needed" and the time left, the question in plain words, the command in
/// a box that wraps, the answers No / Yes once / Yes for this session, and
/// a bar that runs down with the time. A request to open a web page names
/// its host in the question; the full address is under a disclosure.
///
/// An expired card (timed out, or a day old) is read-only: the pill says
/// Expired, a line says that nobody can answer it, and Clear is its only
/// action. Clear answers No, as Clear Expired does.
///
/// The card is one container with the full spoken line; its answers stay
/// buttons of their own. With `keys` (the newest card, when no app
/// question has them) Esc says No and Return says Yes once. No key says
/// yes for the whole session.
@MainActor
struct AgentRequestCard: View {
    let request: AgentRequestJSON
    var keys = false
    @Environment(AgentStore.self) private var agents
    @State private var failure: String?
    @State private var working = false
    @State private var showAddress = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(now: context.date)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(AgentRequestCopy.spokenText(request, now: context.date)))
                .accessibilityIdentifier("agent-request-" + request.id)
        }
        .disabled(working)
    }

    private func card(now: Date) -> some View {
        let color = AgentCharacter.color(request.harness ?? "")
        let expired = AgentRequestCopy.isExpired(request, now: now)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(expired ? AgentRequestCopy.expiredPill : AgentRequestCopy.pill)
                    .font(.caption.bold())
                    .foregroundStyle(expired ? Color(nsColor: .labelColor) : Color.black)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(expired ? Color(nsColor: .quaternaryLabelColor)
                                                       : Color(nsColor: .systemYellow)))
                    .accessibilityIdentifier("agent-request-pill-" + request.id)
                if let project = AgentRequestCopy.project(request) {
                    Text(verbatim: project).font(.caption).labelInk().lineLimit(1)
                }
                // How old the request is: a request of days ago is not
                // the same as one of a minute ago.
                if let asked = RequestAge.asked(request.created, now: now) {
                    Text(asked)
                        .font(.caption)
                        .labelInk()
                        .lineLimit(1)
                        .accessibilityIdentifier("agent-request-age-" + request.id)
                }
                Spacer(minLength: Space.s)
                if !expired, let left = AgentRequestCopy.timeLeft(request, now: now) {
                    Text(left)
                        .font(.caption.monospacedDigit())
                        .labelInk()
                        .accessibilityIdentifier("agent-request-left-" + request.id)
                }
            }
            HStack(alignment: .top, spacing: Space.s) {
                AgentBadge(color: color, size: IconSize.question)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(AgentRequestCopy.question(request))
                        .font(.headline)
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agent-request-question-" + request.id)
                    if let reason = request.reason {
                        Text(verbatim: reason).font(.callout).labelInk().fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let command = AgentRequestCopy.command(request) {
                // The command wraps: no scroll bar, every word in view.
                CodeText(text: command)
                    .accessibilityIdentifier("agent-request-command-" + request.id)
            }
            if let link = AgentRequestCopy.link(request) {
                DisclosureGroup(isExpanded: $showAddress) {
                    CodeText(text: link)
                        .padding(.top, Space.xs)
                        .accessibilityIdentifier("agent-request-link-" + request.id)
                } label: {
                    Text(AgentRequestCopy.fullAddress).font(.callout).labelInk()
                }
                .accessibilityIdentifier("agent-request-address-" + request.id)
            }
            if let failure {
                // The answer did not reach paddock: a plain sentence, with
                // paddock's line under Details. The card stays.
                InlineProblemView(QuestionProblem.of(failure), id: "agent-answer-failed-" + request.id)
                    .font(.caption)
            }
            if expired {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(AgentRequestCopy.expiredNote)
                        .font(.callout)
                        .labelInk()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agent-request-expired-" + request.id)
                    Spacer(minLength: Space.s)
                    Button { send(.deny) } label: { Text(AgentRequestCopy.clear) }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        .accessibilityIdentifier("agent-request-clear-" + request.id)
                }
            } else {
                HStack(spacing: Space.s) {
                    Spacer(minLength: 0)
                    ForEach(AgentRequestCopy.answers(request, now: now), id: \.self) { answer in
                        button(answer)
                    }
                }
                if let fraction = AgentRequestCopy.fraction(request, now: now) {
                    TimeBar(fraction: fraction)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(Space.m)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func button(_ answer: AgentAnswer) -> some View {
        let base = Button { send(answer) } label: { Text(answer.title) }
            .accessibilityIdentifier("agent-answer-" + answer.rawValue + "-" + request.id)
        switch answer {
        case .once:
            base.buttonStyle(.borderedProminent).keyboardShortcut(keys ? KeyboardShortcut.defaultAction : nil)
        case .deny:
            base.buttonStyle(.bordered).keyboardShortcut(keys ? KeyboardShortcut.cancelAction : nil)
        case .session:
            base.buttonStyle(.bordered)
        }
    }

    private func send(_ answer: AgentAnswer) {
        working = true
        Task {
            failure = await agents.answer(request, answer)
            working = false
        }
    }
}

/// A command or an address in a box: monospaced, selectable, and wrapped
/// over as many lines as it needs. Never a horizontal scroll.
struct CodeText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.callout.monospaced())
            .foregroundStyle(Color(nsColor: .textColor))
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.banner, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    .accessibilityHidden(true)
            }
    }
}

/// The time left as a bar that runs down: the accent color, orange in the
/// last fifth.
struct TimeBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .separatorColor))
                Capsule()
                    .fill(fraction < 0.2 ? Color.orange : Color.accentColor)
                    .frame(width: max(0, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

/// The order of the request cards: the newest first, as the questions.
enum AgentRequestOrder {
    static func newestFirst(_ requests: [AgentRequestJSON]) -> [AgentRequestJSON] {
        requests.enumerated().sorted { a, b in
            switch (a.element.created, b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}
