import Foundation

/// An error as the window shows it, in the place where it happened: one
/// plain sentence that names the next step, and paddock's own line for
/// the "Details" disclosure. The line of the CLI is never the message.
public struct InlineProblem: Equatable, Sendable {
    public var message: UIText
    /// paddock's line, word for word. Nil when the message says it all.
    public var details: String?

    public init(message: UIText, details: String? = nil) {
        self.message = message
        self.details = details
    }
}

/// Plain sentences for the lines that paddock's CLI prints when a command
/// fails. The launcher reads the line only to choose the sentence: the
/// line itself goes under "Details".
public enum PlainError {
    public static let generic = UIText("paddock could not do this. Try again. The details say what paddock reported.")
    public static let noAnswer = UIText("paddock did not answer in time. Try again.")
    public static let noSpace = UIText("There is not enough free disk space. Free some space, then try again.")
    public static let needsBaseImage = UIText("Mac apps need the base image. Build it first.")
    public static let stillRunning = UIText("The app is still running. Stop it, then try again.")
    public static let noNetwork = UIText("The connection dropped. Check your network, then try again.")
    public static let notAllowed = UIText("macOS did not allow this. Check the permissions of paddock in System Settings, then try again.")
    public static let oldPaddock = UIText("This paddock does not know this command. Update paddock, then try again.")
    public static let notConfirmed = UIText("This question is no longer confirmed. Refresh to check it.")

    /// The lines that the launcher wrote itself: they are sentences
    /// already and have no CLI line behind them.
    static let own: [String: UIText] = [
        LibraryCopy.offline.english: LibraryCopy.offline,
        LibraryCopy.noAnswer.english: LibraryCopy.noAnswer,
        UIText("paddock is not installed").english: LibraryCopy.offline,
        UIText("paddock is not reachable").english: LibraryCopy.offline,
        UIText("paddock did not answer").english: PlainError.noAnswer,
        UIText("paddock did not list the apps. Click Try Again.").english: UIText("paddock did not list the apps. Click Try Again."),
        UIText("This request cannot be allowed for the session.").english: UIText("This request cannot be allowed for the session."),
        PlainError.notConfirmed.english: PlainError.notConfirmed,
    ]

    /// The problem of a failed command, from paddock's line.
    public static func problem(_ line: String) -> InlineProblem {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mine = own[trimmed] { return InlineProblem(message: mine) }
        return InlineProblem(message: sentence(trimmed), details: trimmed.isEmpty ? nil : trimmed)
    }

    /// A line of paddock as a text for a toast or a row. The launcher's
    /// own lines are texts already. A line of paddock shows as it is in
    /// English; another language gets its catalog text, else the plain
    /// sentence of `sentence`.
    public static func shown(_ line: String) -> UIText {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mine = own[trimmed] { return mine }
        return UIText.cli(line, else: sentence(trimmed))
    }

    /// The sentence for a line of the CLI. An unknown line gets the
    /// general sentence; it never shows as the message.
    public static func sentence(_ line: String) -> UIText {
        let text = line.lowercased()
        if text.isEmpty { return generic }
        if text.contains("did not answer") || text.contains("timed out") || text.contains("timeout") { return noAnswer }
        if text.contains("macvm setup") || text.contains("golden") || text.contains("base image") { return needsBaseImage }
        if text.contains("stop it first") || text.contains("is running") || text.contains(" runs.") || text.contains("still running") {
            return stillRunning
        }
        if text.contains("no space") || text.contains("disk is full") || text.contains("gib free") || text.contains("gb free")
            || text.contains("not enough space") || text.contains("free space") {
            return noSpace
        }
        if text.contains("not permitted") || text.contains("permission denied") || text.contains("not authorized")
            || text.contains("entitlement") {
            return notAllowed
        }
        if text.contains("connection") || text.contains("network") || text.contains("offline") || text.contains("could not resolve") {
            return noNetwork
        }
        if text.contains("unrecognized") || text.contains("unexpected argument") || text.contains("unknown command")
            || text.contains("usage:") || text.contains("no fixture") {
            return oldPaddock
        }
        return generic
    }
}

extension LauncherError {
    /// paddock's own line of a failed command. The window shows it under
    /// "Details", never as the message.
    public var cliLine: String? {
        switch self {
        case .command(_, let line), .appCopyFailed(_, let line): return line
        default: return nil
        }
    }

    /// The sentence under the title: `body`, or for a failed command the
    /// plain sentence of its line.
    public var message: UIText? {
        guard let line = cliLine else { return body }
        return PlainError.problem(line).message
    }

    /// The text of the "Details" disclosure, or nil when there is none.
    public var details: String? {
        cliLine.flatMap { PlainError.problem($0).details }
    }

    /// The error as one inline problem.
    public var problem: InlineProblem {
        InlineProblem(message: message ?? PlainError.generic, details: details)
    }
}

extension BuildFailure {
    /// True when `reason` is the last line of the build child (its stderr),
    /// not a line of paddock's setup report.
    public var reasonIsRaw: Bool { code == "exited" || code == "unreadable" }

    /// What the base image page shows for the failure: the reason of
    /// paddock's report as it is, or a plain sentence with the raw line
    /// under "Details".
    public var problem: InlineProblem {
        let stopped = UIText("The build stopped before the base image was ready. Try Again continues where it stopped.")
        if reason.isEmpty { return InlineProblem(message: stopped) }
        if reasonIsRaw {
            let plain = PlainError.problem(reason)
            // A sentence of the launcher stands for itself.
            if plain.details == nil { return plain }
            return InlineProblem(message: plain.message == PlainError.generic ? stopped : plain.message, details: reason)
        }
        return InlineProblem(message: UIText.cli(reason, else: stopped))
    }
}
