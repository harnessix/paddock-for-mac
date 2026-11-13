import Foundation

/// One notification of the agent rooms.
public struct AgentNotice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case waiting, ended, failed
    }

    /// The notification id: one per request, one per run end.
    public var id: String
    public var kind: Kind
    /// The room to show on a click.
    public var key: String
    public var title: UIText
    public var body: UIText
}

/// When an agent waits for you or ends, a notification shows. It uses the
/// setting of the app questions: a request notifies after it waited
/// `threshold` seconds, the end of a run at once, and "Never" turns both
/// off. A run that had ended before the launcher saw it live does not
/// notify: an old run in `ps` is not news.
public struct AgentNotifier: Equatable, Sendable {
    public private(set) var notified: Set<String> = []
    /// The rooms the notifier saw live.
    public private(set) var seenLive: Set<String> = []

    public init() {}

    public mutating func update(_ rooms: [AgentRoom], now: Date, threshold: TimeInterval?) -> [AgentNotice] {
        var out: [AgentNotice] = []
        for room in rooms {
            let identities = [room.key] + (room.runID.map { [$0] } ?? [])
            if room.state.isLive {
                seenLive.formUnion(identities)
            }
            guard let threshold else { continue }
            for request in room.requests {
                let id = "agent-request-" + request.id
                guard !notified.contains(id) else { continue }
                let opened = request.created ?? now
                guard now.timeIntervalSince(opened) >= threshold else { continue }
                notified.insert(id)
                out.append(AgentNotice(id: id, kind: .waiting, key: room.key,
                                       title: UIText("%@ in %@ is waiting for you", room.title, room.projectText),
                                       body: AgentRequestCopy.question(request)))
            }
            switch room.state {
            case .ended, .failed:
                let id = "agent-end-" + (room.runID ?? room.key)
                guard !notified.contains(id), !seenLive.isDisjoint(with: identities) else { continue }
                notified.insert(id)
                let failed: Bool
                if case .failed = room.state { failed = true } else { failed = false }
                out.append(AgentNotice(id: id, kind: failed ? .failed : .ended, key: room.key,
                                       title: failed ? UIText("%@ in %@ failed", room.title, room.projectText)
                                           : UIText("%@ in %@ ended", room.title, room.projectText),
                                       body: room.state.line))
            default:
                break
            }
        }
        return out
    }
}

/// The card of an agent request, as the card of the video: the pill
/// "Approval needed", the time left, the question, the command in a code
/// box, the answers and a time bar.
public enum AgentRequestCopy {
    public static let pill = UIText("Approval needed")

    /// The question in plain words, from the capability.
    public static func question(_ request: AgentRequestJSON) -> UIText {
        let agent = AgentCharacter.title(request.harness ?? "")
        let who = request.harness == nil ? UIText("An agent") : UIText.verbatim(agent)
        switch request.capability {
        case "exec": return UIText("%@ wants to run a command on your Mac", who)
        case "push", "git-push": return UIText("%@ wants to push to a git remote", who)
        case "fetch": return UIText("%@ wants to read a file of your Mac", who)
        case "open-url":
            if let host = host(request) { return UIText("%@ wants to open %@ in your browser", who, host) }
            return UIText("%@ wants to open a web page", who)
        case "screenshot": return UIText("%@ wants a screenshot of your screen", who)
        case "clipboard-read": return UIText("%@ wants to read your clipboard", who)
        case "clipboard-write": return UIText("%@ wants to change your clipboard", who)
        case "device": return UIText("%@ wants to use a device", who)
        case "serve", "server", "port", "ports": return UIText("%@ wants to open a new server", who)
        default:
            if let summary = request.summary { return UIText("%@ asks: %@", who, summary) }
            return UIText("%@ asks for %@", who, request.capability)
        }
    }

    /// The text of the code box: paddock's detail, else its summary. A
    /// request to open a web page has no code box: its address is `link`.
    public static func command(_ request: AgentRequestJSON) -> String? {
        if link(request) != nil { return nil }
        let text = request.detail ?? request.summary
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// The full web address of a request to open a page, from paddock's
    /// detail or summary: `Open in the host browser: https://…` gives the
    /// address after the words. nil for other requests.
    public static func link(_ request: AgentRequestJSON) -> String? {
        guard request.capability == "open-url" else { return nil }
        for text in [request.detail, request.summary].compactMap({ $0 }) {
            if let address = firstAddress(in: text) { return address }
        }
        return nil
    }

    /// The host of `link`: `accounts.google.com`.
    public static func host(_ request: AgentRequestJSON) -> String? {
        guard let link = link(request), let host = URLComponents(string: link)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// The first `http://` or `https://` address in a text, up to a space.
    static func firstAddress(in text: String) -> String? {
        let starts = ["https://", "http://"].compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }
        guard let start = starts.min() else { return nil }
        let address = text[start...].prefix { !$0.isWhitespace && !"\"<>".contains($0) }
        let clean = String(address).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]'"))
        guard let host = URLComponents(string: clean)?.host, !host.isEmpty else { return nil }
        return clean
    }

    /// The disclosure of the full web address on the card.
    public static let fullAddress = UIText("Full address")

    // MARK: Expired

    /// True when nobody can answer the request any more: it timed out, or
    /// waited for a day (`RequestAge`). Its card is read-only then.
    public static func isExpired(_ request: AgentRequestJSON, now: Date) -> Bool {
        RequestAge.isExpired(request, now: now)
    }

    /// The pill of an expired card, in place of "Approval needed".
    public static let expiredPill = UIText("Expired")
    /// The line of an expired card, above its only action.
    public static let expiredNote = UIText("This request expired. You can no longer answer it.")
    /// The only action of an expired card: it answers No and removes the card.
    public static let clear = UIText("Clear")

    /// The seconds left, or nil when the request does not time out.
    public static func secondsLeft(_ request: AgentRequestJSON, now: Date) -> Double? {
        guard let expires = request.expires else { return nil }
        return max(0, expires.timeIntervalSince(now))
    }

    /// `1:45 left`, `less than a minute left`, or nil.
    public static func timeLeft(_ request: AgentRequestJSON, now: Date) -> UIText? {
        guard let seconds = secondsLeft(request, now: now) else { return nil }
        if seconds <= 0 { return UIText("Timed out") }
        let whole = Int(seconds.rounded(.up))
        return UIText("%@ left", String(format: "%ld:%02ld", whole / 60, whole % 60))
    }

    /// The share of the time that is left, 1 to 0, for the time bar.
    public static func fraction(_ request: AgentRequestJSON, now: Date) -> Double? {
        guard let expires = request.expires, let created = request.created else { return nil }
        let total = expires.timeIntervalSince(created)
        guard total > 0 else { return nil }
        return min(1, max(0, expires.timeIntervalSince(now) / total))
    }

    /// The answers of the card, in order: No, Yes once, and Yes for this
    /// session when paddock allows it.
    public static func answers(_ request: AgentRequestJSON) -> [AgentAnswer] {
        request.sessionAllowed ? [.deny, .once, .session] : [.deny, .once]
    }

    /// The answers at `now`: none once the request expired.
    public static func answers(_ request: AgentRequestJSON, now: Date) -> [AgentAnswer] {
        isExpired(request, now: now) ? [] : answers(request)
    }

    /// The spoken label of the card.
    public static func spoken(_ request: AgentRequestJSON, now: Date) -> String {
        spokenText(request, now: now).english
    }

    /// The spoken label as a text, for the language of the interface.
    public static func spokenText(_ request: AgentRequestJSON, now: Date) -> UIText {
        if isExpired(request, now: now) { return UIText.list([expiredPill, question(request), expiredNote]) }
        var parts = [pill, question(request)]
        if let command = command(request) { parts.append(UIText.verbatim(command)) }
        if let left = timeLeft(request, now: now) { parts.append(left) }
        return UIText.list(parts)
    }

    /// The project of the request: `my-app`.
    public static func project(_ request: AgentRequestJSON) -> String? {
        request.project.map { ($0 as NSString).lastPathComponent }
    }
}

// MARK: - Menu bar

/// One running agent in the menu of the status item.
public struct AgentMenuItem: Equatable, Sendable, Identifiable {
    public var key: String
    public var title: UIText
    public var state: AgentState

    public var id: String { key }

    /// `Claude Code in my-app — Waiting for you`.
    public var line: UIText { UIText("%@ — %@", title, state.line) }
}

extension MenuModel {
    /// The running agents of the menu, the most urgent first, at most
    /// `maxApps`.
    public static func agents(_ rooms: [AgentRoom]) -> [AgentMenuItem] {
        rooms.filter { $0.state.isLive || $0.paneRunning }
            .prefix(maxApps)
            .map { AgentMenuItem(key: $0.key, title: AgentCopy.title($0), state: $0.state) }
    }

    /// The first line of the menu: how many agents run now.
    public static func agentsHeader(_ count: Int) -> UIText {
        switch count {
        case 0: return UIText("No agents running")
        case 1: return UIText("1 agent running")
        default: return UIText("%lld agents running", count)
        }
    }

    /// `Agent requests… (2)`, or nil when none waits.
    public static func agentRequestsItem(_ count: Int) -> UIText? {
        count > 0 ? UIText("Agent requests… (%@)", "\(count)") : nil
    }
}

/// The question before the launcher quits with agents in its panes.
public enum AgentQuitCopy {
    public static func question(_ count: Int) -> UIText {
        count == 1 ? UIText("Quit and stop 1 agent?") : UIText("Quit and stop %lld agents?", count)
    }

    public static let detail = UIText("The agents in the terminal panes of paddock for Mac stop when it quits. Their work in the project folders stays.")
}
